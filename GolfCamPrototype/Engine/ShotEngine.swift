import AVFoundation
import Combine
import CoreGraphics
import simd

struct EngineSettings {
    var targetOnRight = true
    var rightHanded = true
    var zoneCenter: CGPoint?       // buffer px; nil = default placement box
    var zoneHalfSize: Double = 170
    var saveFrames = false
    var club = "7I"
}

/// The shot state machine. Runs on the camera's video queue (240 calls/s), so per-frame work is kept tiny:
///
///   searching/settling: every 8th frame, look for a stationary ball in the placement box
///   armed:              copy luma into the ring buffer; compare the address disc to its reference
///   capturing:          after the trigger, keep recording `postFrames` more, then freeze the ring
///   analyzing:          ShotAnalyzer runs on a separate queue; incoming frames are ignored
///   result / noShot:    wait for NEW SHOT (or auto-return after a false trigger)
final class ShotEngine: ObservableObject {
    enum Phase: String {
        case waitingForCamera = "STARTING"
        case searching = "LOOKING FOR BALL"
        case settling = "HOLD STILL"
        case armed = "READY"
        case capturing = "CAPTURING"
        case analyzing = "ANALYZING"
        case result = "RESULT"
        case noShot = "NO SHOT"
    }

    // MARK: Published UI state (main thread)
    @Published private(set) var phase: Phase = .waitingForCamera
    @Published private(set) var ball: BallObservation?
    @Published private(set) var zone: PixelRect?
    @Published private(set) var bufferSize: CGSize = .zero
    @Published private(set) var measuredFPS: Double = 0
    @Published private(set) var droppedFrames = 0
    @Published private(set) var discMAD: Double = 0
    @Published private(set) var triggerThreshold: Double = 0
    @Published private(set) var attitude: (pitch: Double, roll: Double)?
    @Published private(set) var intrinsicsSummary = "—"
    @Published private(set) var lastShot: ShotRecord?
    @Published private(set) var message = ""

    // MARK: Dependencies
    let motion: MotionManager
    let logger = DebugLogger()
    weak var camera: CameraManager?
    private let videoQueue: DispatchQueue
    private let analysisQueue = DispatchQueue(label: "golfcam.analysis", qos: .userInitiated)

    // MARK: Settings (any thread)
    private let settingsLock = NSLock()
    private var _settings = EngineSettings()
    var settings: EngineSettings {
        settingsLock.lock(); defer { settingsLock.unlock() }
        return _settings
    }

    // MARK: Tunables
    static let preFrames = 32
    static let postFrames = 48
    static let detectEvery = 8
    static let stableCount = 10
    static let baselineFrames = 24

    // MARK: Video-queue state
    private var vPhase: Phase = .waitingForCamera
    private var frameCounter = 0
    private var lastTimestamp: Double?
    private var fpsEMA = 0.0
    private var dropped = 0
    private var width = 0
    private var height = 0
    private var intrinsics: CameraIntrinsics?
    private var history: [BallObservation] = []
    private var address: BallObservation?
    private var disc: DiscReference?
    private var ring: FrameRing?
    private var armedFrames = 0
    private var noiseMax = 0.0
    private var threshold = 0.0
    private var lastMAD = 0.0
    private var triggerFrameNumber = 0
    private var triggerMAD = 0.0
    private var postRemaining = 0
    private var triggerGravity: SIMD3<Double>?
    private var triggerExposure: CameraManager.ExposureSnapshot?

    init(motion: MotionManager, videoQueue: DispatchQueue) {
        self.motion = motion
        self.videoQueue = videoQueue
    }

    // MARK: - Public controls (main thread)

    func updateSettings(_ change: (inout EngineSettings) -> Void) {
        settingsLock.lock()
        change(&_settings)
        settingsLock.unlock()
    }

    func setZoneCenter(_ p: CGPoint) {
        updateSettings { $0.zoneCenter = p }
        videoQueue.async { self.resetToSearching() }
    }

    func resetZone() {
        updateSettings { $0.zoneCenter = nil }
        videoQueue.async { self.resetToSearching() }
    }

    func newShot() {
        videoQueue.async { self.resetToSearching() }
    }

    func noteDroppedFrame() { dropped += 1 }   // called on the video queue

    // MARK: - Per-frame entry point (video queue)

    func process(_ sampleBuffer: CMSampleBuffer) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Always use the real presentation timestamp — never assume a perfect 1/240 s.
        let t = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        frameCounter += 1
        trackFrameRate(t)

        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        if w != width || h != height {
            width = w; height = h
            ring = nil; intrinsics = nil
            DispatchQueue.main.async { self.bufferSize = CGSize(width: w, height: h) }
            resetToSearching()
        }
        if intrinsics == nil || frameCounter % 480 == 0 { updateIntrinsics(sampleBuffer) }

        switch vPhase {
        case .waitingForCamera, .searching, .settling:
            if frameCounter % Self.detectEvery == 0 {
                CVPixelBufferLockBaseAddress(pb, .readOnly)
                if let view = LumaView(lockedPixelBuffer: pb) { runDetection(view) }
                CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            }
        case .armed, .capturing:
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            recordArmedFrame(pb, t)
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        case .analyzing, .result, .noShot:
            break
        }

        if frameCounter % 24 == 0 { publishTelemetry() }
    }

    // MARK: - Detection / arming

    private func currentZone(_ s: EngineSettings) -> PixelRect {
        // Default box sits on the side away from the target so the ball crosses most of the frame.
        let c = s.zoneCenter ?? CGPoint(x: Double(width) * (s.targetOnRight ? 0.3 : 0.7), y: Double(height) * 0.62)
        return PixelRect.centered(x: Double(c.x), y: Double(c.y), halfSize: s.zoneHalfSize)
            .clipped(width: width, height: height)
    }

    private func runDetection(_ view: LumaView) {
        let zone = currentZone(settings)
        let obs = BallDetector.findStationaryBall(in: view, zone: zone, minRadius: 4, maxRadius: 60)
        DispatchQueue.main.async {
            self.ball = obs
            self.zone = zone
        }
        guard let obs else {
            history.removeAll()
            if vPhase != .searching { setPhase(.searching) }
            return
        }
        if let last = history.last, hypot(obs.x - last.x, obs.y - last.y) > 3 || abs(obs.radius - last.radius) > 2 {
            history.removeAll()
        }
        history.append(obs)
        if history.count > Self.stableCount { history.removeFirst() }

        if history.count >= Self.stableCount && isStable(history) {
            arm(view)
        } else if vPhase != .settling {
            setPhase(.settling)
        }
    }

    private func isStable(_ h: [BallObservation]) -> Bool {
        func std(_ v: [Double]) -> Double {
            let m = v.reduce(0, +) / Double(v.count)
            return (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count)).squareRoot()
        }
        return std(h.map(\.x)) < 0.8 && std(h.map(\.y)) < 0.8 && std(h.map(\.radius)) < 0.6
    }

    private func arm(_ view: LumaView) {
        guard var mean = history.last else { return }
        let n = Double(history.count)
        // Averaging ~10 stationary detections gives the best radius we get, which sets the speed scale.
        mean.x = history.map(\.x).reduce(0, +) / n
        mean.y = history.map(\.y).reduce(0, +) / n
        mean.radius = history.map(\.radius).reduce(0, +) / n
        guard let d = DiscReference(view: view, x: mean.x, y: mean.y, radius: max(2, mean.radius * 0.6)) else { return }

        if ring == nil || ring!.width != width || ring!.height != height {
            // (32 + 48) × ~2 MB ≈ 166 MB at 1080p.
            ring = FrameRing(capacity: Self.preFrames + Self.postFrames, width: width, height: height)
        }
        ring?.reset()
        address = mean
        disc = d
        armedFrames = 0
        noiseMax = 0
        threshold = 0
        camera?.lockFocusAndWhiteBalance()
        setPhase(.armed)
        DispatchQueue.main.async { self.ball = mean }
    }

    // MARK: - Armed recording / trigger

    private func recordArmedFrame(_ pb: CVPixelBuffer, _ t: Double) {
        guard let ring, var disc else { return }
        let slot = ring.nextSlot()
        guard slot.copyLuma(from: pb) else { return }
        slot.timestamp = t
        slot.frameNumber = frameCounter
        ring.commit()

        let mad = disc.meanAbsDiff(slot.view)
        lastMAD = mad

        if vPhase == .capturing {
            postRemaining -= 1
            if postRemaining <= 0 { beginAnalysis() }
            return
        }

        armedFrames += 1
        if armedFrames <= Self.baselineFrames {
            // Learn the noise floor of the disc comparison before allowing a trigger.
            noiseMax = max(noiseMax, mad)
            threshold = max(15, 3 * noiseMax + 6)
            return
        }
        if mad > threshold {
            triggerFrameNumber = frameCounter
            triggerMAD = mad
            postRemaining = Self.postFrames
            triggerGravity = motion.gravityInCamera
            triggerExposure = camera?.exposureSnapshot()
            setPhase(.capturing)
        } else if armedFrames % 240 == 0 && mad < threshold * 0.4 {
            disc.refresh(from: slot.view)
            self.disc = disc
        }
    }

    // MARK: - Analysis

    private func beginAnalysis() {
        setPhase(.analyzing)
        guard let ring, let address, let disc else { resetToSearching(); return }
        let frames = ring.ordered()
        guard let trig = frames.firstIndex(where: { $0.frameNumber == triggerFrameNumber }) else {
            resetToSearching(); return
        }
        let K = intrinsics ?? fallbackIntrinsics()
        let s = settings
        let gravity = triggerGravity
        let exposure = triggerExposure
        let thr = threshold
        let tMAD = triggerMAD
        let fps = fpsEMA

        analysisQueue.async { [weak self] in
            guard let self else { return }
            var cfg = ShotAnalyzerConfig()
            cfg.targetSign = s.targetOnRight ? 1 : -1
            // Face-on camera, right-handed golfer, target to image right → "away from camera" is a pull (LEFT).
            // Each mismatch (left-handed, or camera behind the golfer) flips it.
            cfg.awayIsLeft = (s.rightHanded == s.targetOnRight)
            let analysis = ShotAnalyzer.analyze(frames: frames, triggerPosition: trig, address: address, disc: disc,
                                                discThreshold: thr, intrinsics: K, gravityCam: gravity, config: cfg)
            print("[Shot] \(analysis.status.rawValue): \(analysis.message) (\(Int(analysis.analysisMs)) ms)")

            if analysis.status == .noShot {
                DispatchQueue.main.async { self.message = analysis.message }
                self.videoQueue.async {
                    self.setPhase(.noShot)
                    self.videoQueue.asyncAfter(deadline: .now() + 1.5) {
                        if self.vPhase == .noShot { self.resetToSearching() }
                    }
                }
                return
            }

            let shotNumber = self.logger.nextShotNumber()
            let (crop, review) = ReviewBuilder.build(frames: frames, analysis: analysis, address: address)
            let log = ShotLog(
                shotNumber: shotNumber,
                timestamp: ISO8601DateFormatter().string(from: Date()),
                club: s.club,
                device: DebugLogger.deviceModel,
                format: self.camera?.formatDescription ?? "?",
                measuredFPS: fps,
                exposure: exposure,
                intrinsics: K,
                gravityCamera: gravity.map { [$0.x, $0.y, $0.z] },
                address: address,
                triggerThreshold: thr,
                triggerMAD: tMAD,
                targetOnRight: s.targetOnRight,
                rightHanded: s.rightHanded,
                status: analysis.status.rawValue,
                message: analysis.message,
                confidence: analysis.confidence,
                frameTimesRelTrigger: analysis.frameTimes,
                candidates: analysis.candidates,
                fit: analysis.fit,
                metrics: analysis.metrics,
                notes: analysis.notes,
                analysisMs: analysis.analysisMs)
            let saveFrames = s.saveFrames ? Array(frames[analysis.windowStart...analysis.windowEnd]) : nil
            self.logger.save(log, frames: saveFrames)

            let record = ShotRecord(shotNumber: shotNumber, club: s.club, date: Date(), analysis: analysis,
                                    address: address, crop: crop, reviewFrames: review)
            DispatchQueue.main.async {
                self.lastShot = record
                self.message = analysis.message
            }
            self.videoQueue.async { self.setPhase(.result) }
        }
    }

    // MARK: - Helpers (video queue)

    private func resetToSearching() {
        history.removeAll()
        address = nil
        disc = nil
        setPhase(.searching)
        camera?.resumeAutoFocus()
    }

    private func setPhase(_ p: Phase) {
        guard p != vPhase else { return }
        vPhase = p
        DispatchQueue.main.async { self.phase = p }
    }

    private func trackFrameRate(_ t: Double) {
        if let last = lastTimestamp {
            let dt = t - last
            if dt > 0 && dt < 0.1 {
                let inst = 1 / dt
                fpsEMA = fpsEMA == 0 ? inst : fpsEMA * 0.98 + inst * 0.02
            }
        }
        lastTimestamp = t
    }

    /// Intrinsics come from the ISP per frame (in the output buffer's pixel units) when supported.
    private func updateIntrinsics(_ sampleBuffer: CMSampleBuffer) {
        var k: CameraIntrinsics?
        if let data = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                                      attachmentModeOut: nil) as? Data, data.count >= 48 {
            // matrix_float3x3: 3 columns of float4 (padded). fx=[0], fy=[5], cx=[8], cy=[9].
            var m = [Float](repeating: 0, count: 12)
            m.withUnsafeMutableBytes { raw in _ = data.copyBytes(to: raw, count: 48) }
            let cand = CameraIntrinsics(fx: Double(m[0]), fy: Double(m[5]), cx: Double(m[8]), cy: Double(m[9]),
                                        width: width, height: height, source: "ISP per-frame matrix")
            // Sanity check: principal point near the centre of this buffer.
            if cand.fx > 100, abs(cand.cx - Double(width) / 2) < 0.2 * Double(width),
               abs(cand.cy - Double(height) / 2) < 0.2 * Double(height) {
                k = cand
            }
        }
        let result = k ?? fallbackIntrinsics()
        intrinsics = result
        let text = String(format: "fx %.0f fy %.0f c(%.0f, %.0f) · %@", result.fx, result.fy, result.cx, result.cy, result.source)
        DispatchQueue.main.async { self.intrinsicsSummary = text }
    }

    private func fallbackIntrinsics() -> CameraIntrinsics {
        let fov = (camera?.fieldOfViewDegrees ?? 0) > 1 ? camera!.fieldOfViewDegrees : 70
        let fx = (Double(width) / 2) / tan(fov * .pi / 360)
        return CameraIntrinsics(fx: fx, fy: fx, cx: Double(width) / 2, cy: Double(height) / 2,
                                width: width, height: height, source: "FOV fallback")
    }

    private func publishTelemetry() {
        let fps = fpsEMA, drops = dropped, mad = lastMAD, thr = threshold
        let att = motion.gravityInCamera.map { MotionManager.attitude(gravityCam: $0) }
        DispatchQueue.main.async {
            self.measuredFPS = fps
            self.droppedFrames = drops
            self.discMAD = mad
            self.triggerThreshold = thr
            self.attitude = att
        }
    }
}
