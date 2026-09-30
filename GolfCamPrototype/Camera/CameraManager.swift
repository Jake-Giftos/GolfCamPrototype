import AVFoundation
import Combine
import UIKit

/// Configures the rear wide camera for the highest available frame rate (240 fps on iPhone 17 Pro Max at 1080p),
/// a short manual shutter to limit motion blur, and delivers raw 4:2:0 frames to the ShotEngine.
///
/// Geometry note: we never rotate the video connection. Frames stay in the sensor's native landscape orientation,
/// so pixel axes are fixed relative to the phone body. MotionManager relies on this to map gravity into image axes.
final class CameraManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published private(set) var formatDescription = "—"
    @Published private(set) var nominalFPS: Double = 0
    @Published private(set) var exposureDescription = "—"
    @Published private(set) var errorMessage: String?

    let session = AVCaptureSession()
    let videoQueue = DispatchQueue(label: "golfcam.video", qos: .userInteractive)
    private let sessionQueue = DispatchQueue(label: "golfcam.session")
    private let videoOutput = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var isConfigured = false
    /// Auto-exposure reading taken before switching to manual; used to keep brightness when shortening the shutter.
    private var baseline: (duration: Double, iso: Float)?

    weak var engine: ShotEngine?

    /// Horizontal field of view of the active format (degrees). Used only if intrinsics are not delivered.
    private(set) var fieldOfViewDegrees: Double = 0

    /// Target shutter speed as 1/x seconds. Shorter = less blur but darker/noisier.
    var shutterDenominator: Double = 4000 {
        didSet { applyFastShutter() }
    }

    struct ExposureSnapshot: Codable {
        var durationS: Double
        var iso: Double
        var lensPosition: Double
    }

    // MARK: - Lifecycle

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            sessionQueue.async { self.configureAndStart() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    self.sessionQueue.async { self.configureAndStart() }
                } else {
                    self.report("Camera access denied. Enable it in Settings › GolfCam.")
                }
            }
        default:
            report("Camera access denied. Enable it in Settings › GolfCam.")
        }
    }

    private func configureAndStart() {
        if isConfigured {
            if !session.isRunning { session.startRunning() }
            return
        }
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            report("No rear wide camera found"); return
        }
        guard let choice = Self.bestHighSpeedFormat(for: dev) else {
            report("No compatible 4:2:0 video format found"); return
        }

        session.beginConfiguration()
        // .inputPriority lets us pick the device format directly instead of a session preset.
        session.sessionPreset = .inputPriority
        do {
            let input = try AVCaptureDeviceInput(device: dev)
            guard session.canAddInput(input) else {
                session.commitConfiguration(); report("Cannot add camera input"); return
            }
            session.addInput(input)
        } catch {
            session.commitConfiguration(); report("Camera input error: \(error.localizedDescription)"); return
        }

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: choice.pixelFormat]
        // Keep every frame we can; per-frame work is small (a luma memcpy + a tiny disc comparison).
        videoOutput.alwaysDiscardsLateVideoFrames = false
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(videoOutput) else {
            session.commitConfiguration(); report("Cannot add video output"); return
        }
        session.addOutput(videoOutput)

        do {
            try dev.lockForConfiguration()
            dev.activeFormat = choice.format
            dev.activeVideoMinFrameDuration = choice.frameDuration
            dev.activeVideoMaxFrameDuration = choice.frameDuration
            if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
            if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
            if dev.isLowLightBoostSupported { dev.automaticallyEnablesLowLightBoostWhenAvailable = false }
            dev.unlockForConfiguration()
        } catch {
            report("Could not lock camera for configuration: \(error.localizedDescription)")
        }

        if let conn = videoOutput.connection(with: .video) {
            // Stabilization crops/warps frames, which would break pixel → ray geometry.
            if conn.isVideoStabilizationSupported { conn.preferredVideoStabilizationMode = .off }
            // Per-frame fx, fy, cx, cy from the ISP. Much better than guessing from the FOV.
            if conn.isCameraIntrinsicMatrixDeliverySupported { conn.isCameraIntrinsicMatrixDeliveryEnabled = true }
            // Native sensor orientation (see type comment).
            if conn.isVideoRotationAngleSupported(0) { conn.videoRotationAngle = 0 }
        }
        session.commitConfiguration()

        device = dev
        fieldOfViewDegrees = Double(choice.format.videoFieldOfView)
        isConfigured = true
        session.startRunning()

        // Committing a configuration can reset the frame duration; re-assert it.
        do {
            try dev.lockForConfiguration()
            dev.activeVideoMinFrameDuration = choice.frameDuration
            dev.activeVideoMaxFrameDuration = choice.frameDuration
            dev.unlockForConfiguration()
        } catch {}

        let dims = CMVideoFormatDescriptionGetDimensions(choice.format.formatDescription)
        let fps = 1.0 / choice.frameDuration.seconds
        let range = choice.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? "full" : "video"
        let text = "\(dims.width)x\(dims.height) @ \(Int(fps.rounded())) fps (\(range) range)"
        DispatchQueue.main.async {
            self.formatDescription = text
            self.nominalFPS = fps
        }
        // Let auto-exposure settle on the scene, then switch to a fast manual shutter with matched brightness.
        sessionQueue.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.applyFastShutterNow() }
    }

    struct FormatChoice {
        let format: AVCaptureDevice.Format
        let frameDuration: CMTime
        let pixelFormat: OSType
    }

    /// Highest frame rate first, then the largest width up to 1920 (1080p is plenty and keeps the per-frame
    /// copy at ~2 MB), preferring full-range luma.
    static func bestHighSpeedFormat(for device: AVCaptureDevice) -> FormatChoice? {
        var best: FormatChoice?
        var bestKey: (Double, Int32, Int) = (0, 0, 0)
        for format in device.formats {
            let sub = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            let fullRange = sub == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            guard fullRange || sub == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { continue }
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.width <= 1920, dims.height <= 1080 else { continue }
            guard let range = format.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) else { continue }
            let key = (range.maxFrameRate.rounded(), dims.width, fullRange ? 1 : 0)
            if best == nil || key > bestKey {
                best = FormatChoice(format: format, frameDuration: range.minFrameDuration, pixelFormat: sub)
                bestKey = key
            }
        }
        return best
    }

    // MARK: - Exposure / focus

    func applyFastShutter() {
        sessionQueue.async { [weak self] in self?.applyFastShutterNow() }
    }

    /// Sets a custom exposure of 1/shutterDenominator s and scales ISO to keep brightness equal to the
    /// auto-exposure baseline (exposure ∝ duration × ISO). If ISO hits the format max the image gets darker;
    /// that is reported instead of silently lengthening the shutter.
    private func applyFastShutterNow() {
        guard let dev = device else { return }
        let format = dev.activeFormat
        if baseline == nil { baseline = (dev.exposureDuration.seconds, dev.iso) }
        guard let base = baseline, base.duration > 0 else { return }

        let frameDuration = dev.activeVideoMinFrameDuration.seconds
        let minDur = format.minExposureDuration.seconds
        let maxDur = min(format.maxExposureDuration.seconds, frameDuration)
        let target = min(max(1.0 / shutterDenominator, minDur), maxDur)
        var iso = Float(Double(base.iso) * base.duration / target)
        iso = min(max(iso, format.minISO), format.maxISO)

        do {
            try dev.lockForConfiguration()
            dev.setExposureModeCustom(duration: CMTime(seconds: target, preferredTimescale: 1_000_000_000),
                                      iso: iso, completionHandler: nil)
            dev.unlockForConfiguration()
        } catch {
            report("Could not set manual exposure: \(error.localizedDescription)"); return
        }
        var text = String(format: "1/%.0f s · ISO %.0f", 1 / target, iso)
        if iso >= format.maxISO { text += " (ISO maxed — image darker)" }
        DispatchQueue.main.async { self.exposureDescription = text }
    }

    /// Return to auto exposure briefly to re-measure the scene (e.g. clouds moved), then re-apply the fast shutter.
    func remeter() {
        sessionQueue.async { [weak self] in
            guard let self, let dev = self.device else { return }
            do {
                try dev.lockForConfiguration()
                if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
                dev.unlockForConfiguration()
            } catch { return }
            self.baseline = nil
            DispatchQueue.main.async { self.exposureDescription = "metering…" }
            self.sessionQueue.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.applyFastShutterNow() }
        }
    }

    /// Point is normalized (0…1) in native sensor coordinates, i.e. buffer x / width, y / height.
    func focus(atNormalizedPoint p: CGPoint) {
        sessionQueue.async { [weak self] in
            guard let dev = self?.device else { return }
            do {
                try dev.lockForConfiguration()
                if dev.isFocusPointOfInterestSupported { dev.focusPointOfInterest = p }
                if dev.isFocusModeSupported(.autoFocus) { dev.focusMode = .autoFocus }
                dev.unlockForConfiguration()
            } catch {}
        }
    }

    /// Called when the ball is armed so focus/white balance can't drift during the swing.
    func lockFocusAndWhiteBalance() {
        sessionQueue.async { [weak self] in
            guard let dev = self?.device else { return }
            do {
                try dev.lockForConfiguration()
                if dev.isFocusModeSupported(.locked) { dev.focusMode = .locked }
                if dev.isWhiteBalanceModeSupported(.locked) { dev.whiteBalanceMode = .locked }
                dev.unlockForConfiguration()
            } catch {}
        }
    }

    func resumeAutoFocus() {
        sessionQueue.async { [weak self] in
            guard let dev = self?.device else { return }
            do {
                try dev.lockForConfiguration()
                if dev.focusMode == .locked, dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
                if dev.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { dev.whiteBalanceMode = .continuousAutoWhiteBalance }
                dev.unlockForConfiguration()
            } catch {}
        }
    }

    func exposureSnapshot() -> ExposureSnapshot? {
        guard let d = device else { return nil }
        return ExposureSnapshot(durationS: d.exposureDuration.seconds, iso: Double(d.iso), lensPosition: Double(d.lensPosition))
    }

    private func report(_ message: String) {
        print("[Camera] \(message)")
        DispatchQueue.main.async { self.errorMessage = message }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        engine?.process(sampleBuffer)
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        engine?.noteDroppedFrame()
    }
}
