import Foundation
import simd

struct TrackCandidate: Codable, Identifiable {
    var id: Int
    var position: Int       // index into the analysed frame array
    var t: Double           // s relative to the trigger frame
    var x: Double           // px (blob centroid ≈ ball centre at mid-exposure)
    var y: Double
    var radius: Double      // px, from blob minor axis
    var area: Int
    var elongation: Double  // major/minor std — motion blur makes this > 1
    var meanLuma: Double
    var inlier = false
}

struct PixelFit: Codable {
    var x0: Double          // px at t = 0 (trigger frame)
    var y0: Double
    var vx: Double          // px/s
    var vy: Double
    var rmsPx: Double
    var inlierCount: Int
    var impactTime: Double  // s rel. trigger: when the fitted path passes closest to the address point
    var impactMissPx: Double

    func position(at t: Double) -> (x: Double, y: Double) { (x0 + vx * t, y0 + vy * t) }
}

enum AnalysisStatus: String, Codable {
    case measured, noShot, trackingFailed
}

struct ShotAnalysis {
    var status: AnalysisStatus
    var message: String
    var candidates: [TrackCandidate] = []
    var fit: PixelFit?
    var metrics: LaunchMetrics?
    var confidence = "—"
    var notes: [String] = []
    var triggerPosition = 0
    var windowStart = 0
    var windowEnd = 0
    var frameTimes: [Double] = []   // s rel. trigger, for window frames
    var analysisMs = 0.0
}

struct ShotAnalyzerConfig {
    var trackFrames = 24           // ~100 ms after trigger at 240 fps
    var diffThreshold = 18         // luma levels for frame differencing
    var targetSign: Double = 1     // +1: target is toward image right
    var awayIsLeft = true          // for labelling start direction
    var maxCandidatesPerFrame = 6
}

/// Post-impact analysis of the frozen frame window.
///
/// 1. Confirm the ball actually left the address position.
/// 2. For each post-trigger frame, find moving blobs (three-frame differencing) that are ball-sized.
/// 3. RANSAC over candidate pairs for a constant-velocity pixel path that (a) starts at the address point
///    at impact time, (b) heads toward the target, (c) has a plausible speed and elevation. This is what
///    rejects the club head, shaft and golfer.
/// 4. Least-squares refit on inliers (gravity drop over ~20 ms is ~2 mm, so a straight line is fine).
/// 5. Convert to metric speed and launch via LaunchGeometry.
enum ShotAnalyzer {
    static func analyze(frames: [LumaFrame], triggerPosition trig: Int, address: BallObservation,
                        disc: DiscReference, discThreshold: Double, intrinsics K: CameraIntrinsics,
                        gravityCam: SIMD3<Double>?, config: ShotAnalyzerConfig) -> ShotAnalysis {
        let started = CFAbsoluteTimeGetCurrent()
        var result = ShotAnalysis(status: .trackingFailed, message: "")
        result.triggerPosition = trig
        func finish() -> ShotAnalysis {
            result.analysisMs = (CFAbsoluteTimeGetCurrent() - started) * 1000
            return result
        }

        guard frames.count >= 4, trig >= 1, trig <= frames.count - 3 else {
            result.message = "Not enough frames around impact"
            return finish()
        }

        // 1. Did the ball leave?
        let lastMAD = disc.meanAbsDiff(frames[frames.count - 1].view)
        if lastMAD < discThreshold {
            result.status = .noShot
            result.message = String(format: "No shot — ball still at address (diff %.0f < %.0f)", lastMAD, discThreshold)
            return finish()
        }

        let W = frames[0].width, H = frames[0].height
        let r0 = address.radius
        let tTrig = frames[trig].timestamp
        func tRel(_ pos: Int) -> Double { frames[pos].timestamp - tTrig }
        let intervals = zip(frames.dropFirst(), frames).map { $0.timestamp - $1.timestamp }.filter { $0 > 0 }.sorted()
        let dtFrame = intervals.isEmpty ? 1.0 / 240 : intervals[intervals.count / 2]

        let endPos = min(frames.count - 2, trig + config.trackFrames - 1)
        result.windowStart = max(0, trig - 2)
        result.windowEnd = endPos + 1
        result.frameTimes = (result.windowStart...result.windowEnd).map { tRel($0) }

        // 2. Moving, ball-sized blobs. Search only the target side of the address point.
        let roi = config.targetSign > 0
            ? PixelRect(minX: max(0, Int(address.x - 3 * r0)), minY: 0, maxX: W, maxY: H)
            : PixelRect(minX: 0, minY: 0, maxX: min(W, Int(address.x + 3 * r0)), maxY: H)
        let a0 = Double.pi * r0 * r0
        let minArea = max(10, Int(0.2 * a0))
        let maxArea = Int(8 * a0) + 50
        let sqrt3 = 3.0.squareRoot()

        var cands: [TrackCandidate] = []
        for pos in trig...endPos {
            var mask = BlobLabeler.motionMask(prev: frames[pos - 1].view, cur: frames[pos].view,
                                              next: frames[pos + 1].view, rect: roi, threshold: config.diffThreshold)
            var blobs = BlobLabeler.label(mask: &mask, rect: roi, luma: frames[pos].view, minArea: minArea, maxArea: maxArea)
            blobs.sort { $0.meanLuma > $1.meanLuma }
            var kept = 0
            for b in blobs {
                let axes = b.principalStd
                let elongation = axes.major / max(axes.minor, 0.3)
                // σ_minor → radius: a disc gives r = 2σ; a long blur streak (stadium) tends to r = √3σ.
                let k = sqrt3 + (2 - sqrt3) / (elongation * elongation)
                let radius = k * axes.minor
                guard radius >= 0.35 * r0, radius <= 1.8 * r0, elongation <= 8 else { continue }
                cands.append(TrackCandidate(id: cands.count, position: pos, t: tRel(pos), x: b.centerX, y: b.centerY,
                                            radius: radius, area: b.area, elongation: elongation, meanLuma: b.meanLuma))
                kept += 1
                if kept >= config.maxCandidatesPerFrame { break }
            }
        }
        result.candidates = cands
        guard cands.count >= 3 else {
            result.message = "Ball not found after impact (\(cands.count) moving candidates)"
            result.notes.append("Check blur/exposure and that the ball flies across the frame toward the target side.")
            return finish()
        }

        // 3. RANSAC for the ball path.
        let upCam = LaunchGeometry.upVector(gravityCam).up
        var up2 = SIMD2<Double>(upCam.x, upCam.y)
        up2 = simd_length(up2) > 0.2 ? simd_normalize(up2) : SIMD2(0, -1)
        let along2 = SIMD2<Double>(-up2.y, up2.x) * config.targetSign
        let pxPerM = r0 / LaunchGeometry.ballRadiusM
        let minSpeed = 8.0 * pxPerM     // px/s ≈ 18 mph
        let maxSpeed = 100.0 * pxPerM   // px/s ≈ 224 mph
        let c0 = SIMD2<Double>(address.x, address.y)
        let tol = max(3.0, 0.5 * r0)
        let tPrev = tRel(trig - 1)
        let byPosition = Dictionary(grouping: cands.indices, by: { cands[$0].position })
        let positions = byPosition.keys.sorted()

        /// Best-matching candidate per frame within `tol` of the path p + v·t.
        func gather(_ p: SIMD2<Double>, _ v: SIMD2<Double>) -> (idx: [Int], cost: Double) {
            var idx: [Int] = []
            var cost = 0.0
            for pos in positions {
                var bestI = -1
                var bestD = Double.infinity
                for i in byPosition[pos] ?? [] {
                    let c = cands[i]
                    let d = simd_length(SIMD2(c.x, c.y) - (p + v * c.t))
                    if d < bestD { bestD = d; bestI = i }
                }
                if bestI >= 0 && bestD <= tol { idx.append(bestI); cost += bestD }
            }
            return (idx, cost)
        }

        func plausible(_ p: SIMD2<Double>, _ v: SIMD2<Double>) -> Bool {
            let speed = simd_length(v)
            guard speed >= minSpeed, speed <= maxSpeed else { return false }
            let along = simd_dot(v, along2)
            guard along > 0 else { return false }
            let elevation = atan2(simd_dot(v, up2), along) * 180 / .pi
            guard elevation > -20, elevation < 80 else { return false }
            // The path must pass through the address point around impact.
            let tStar = simd_dot(c0 - p, v) / simd_dot(v, v)
            guard tStar >= tPrev - 1.5 * dtFrame, tStar <= 3 * dtFrame else { return false }
            return simd_length(p + v * tStar - c0) <= max(3.0, 1.2 * r0)
        }

        var best: (idx: [Int], cost: Double)?
        for i in cands.indices {
            for j in cands.indices where cands[j].position > cands[i].position {
                let ci = cands[i], cj = cands[j]
                let v = (SIMD2(cj.x, cj.y) - SIMD2(ci.x, ci.y)) / (cj.t - ci.t)
                let p = SIMD2(ci.x, ci.y) - v * ci.t
                guard plausible(p, v) else { continue }
                let g = gather(p, v)
                if let b = best {
                    if g.idx.count > b.idx.count || (g.idx.count == b.idx.count && g.cost < b.cost) { best = g }
                } else {
                    best = g
                }
            }
        }

        guard var chosen = best?.idx, chosen.count >= 3 else {
            result.message = "No consistent ball path (best: \(best?.idx.count ?? 0) frames)"
            result.notes.append("Candidates were found but none lined up from the address point toward the target.")
            return finish()
        }

        // 4. Least-squares refit, re-gather, repeat until stable.
        func fitLine(_ idx: [Int]) -> (p: SIMD2<Double>, v: SIMD2<Double>, rms: Double)? {
            let ts = idx.map { cands[$0].t }
            guard let fx = LinearFit.fit(ts, idx.map { cands[$0].x }),
                  let fy = LinearFit.fit(ts, idx.map { cands[$0].y }) else { return nil }
            return (SIMD2(fx.intercept, fy.intercept), SIMD2(fx.slope, fy.slope),
                    (fx.rms * fx.rms + fy.rms * fy.rms).squareRoot())
        }
        for _ in 0..<3 {
            guard let f = fitLine(chosen) else { break }
            let regathered = gather(f.p, f.v).idx
            if regathered.count < 3 || regathered == chosen { break }
            chosen = regathered
        }
        guard let line = fitLine(chosen) else {
            result.message = "Line fit failed"
            return finish()
        }
        for i in chosen { cands[i].inlier = true }
        result.candidates = cands

        let tStar = simd_dot(c0 - line.p, line.v) / simd_dot(line.v, line.v)
        let miss = simd_length(line.p + line.v * tStar - c0)
        result.fit = PixelFit(x0: line.p.x, y0: line.p.y, vx: line.v.x, vy: line.v.y, rmsPx: line.rms,
                              inlierCount: chosen.count, impactTime: tStar, impactMissPx: miss)

        // 5. Metric conversion.
        let ordered = chosen.sorted { cands[$0].t < cands[$1].t }
        let points = ordered.map { TrackPoint(t: cands[$0].t, u: cands[$0].x, v: cands[$0].y, radius: cands[$0].radius) }
        var notes: [String] = []
        guard var metrics = LaunchGeometry.computeMetrics(points: points, address: address, K: K, gravityCam: gravityCam,
                                                          awayIsLeft: config.awayIsLeft, notes: &notes) else {
            result.notes += notes
            result.message = "Could not convert track to launch metrics"
            return finish()
        }
        metrics.pixelSpeedPxPerFrame = simd_length(line.v) * dtFrame
        result.metrics = metrics
        result.notes += notes
        result.status = .measured
        result.message = "Shot measured"

        // Confidence is about the track quality only; it says nothing about calibration accuracy.
        if chosen.count >= 5 && line.rms <= 1.0 {
            result.confidence = "HIGH"
        } else if chosen.count >= 4 && line.rms <= 2.0 {
            result.confidence = "MEDIUM"
        } else {
            result.confidence = "LOW"
        }
        if chosen.count < 4 { result.notes.append("Only \(chosen.count) frames tracked — result is rough.") }
        if let first = ordered.first, cands[first].position > trig + 2 {
            result.notes.append("Ball not seen in the first frames after impact.")
        }
        if miss > r0 { result.notes.append(String(format: "Fitted path misses the address point by %.1f px.", miss)) }
        if result.confidence == "LOW" {
            result.metrics?.startDirectionLabel = nil   // too noisy to show
        }
        return finish()
    }
}
