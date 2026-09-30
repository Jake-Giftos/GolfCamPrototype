import Foundation
import simd

struct CameraIntrinsics: Codable {
    var fx: Double
    var fy: Double
    var cx: Double
    var cy: Double
    var width: Int
    var height: Int
    var source: String   // "ISP per-frame matrix" or "FOV fallback"
}

struct LineFit {
    let intercept: Double
    let slope: Double
    let rms: Double
}

enum LinearFit {
    /// Ordinary least squares y = intercept + slope · x.
    static func fit(_ x: [Double], _ y: [Double]) -> LineFit? {
        guard x.count >= 2, x.count == y.count else { return nil }
        let n = Double(x.count)
        let mx = x.reduce(0, +) / n
        let my = y.reduce(0, +) / n
        var sxx = 0.0, sxy = 0.0
        for i in x.indices {
            let dx = x[i] - mx
            sxx += dx * dx
            sxy += dx * (y[i] - my)
        }
        guard sxx > 1e-15 else { return nil }
        let slope = sxy / sxx
        let intercept = my - slope * mx
        var ss = 0.0
        for i in x.indices {
            let r = y[i] - (intercept + slope * x[i])
            ss += r * r
        }
        return LineFit(intercept: intercept, slope: slope, rms: (ss / n).squareRoot())
    }
}

struct TrackPoint {
    let t: Double       // s, relative to trigger frame
    let u: Double       // px
    let v: Double       // px
    let radius: Double  // px (apparent, from blob shape)
}

struct LaunchMetrics: Codable {
    // Primary (flight-plane model)
    var ballSpeedMph: Double
    var ballSpeedMps: Double
    var launchDeg: Double
    var planeFitRmsM: Double
    // Experimental (depth from apparent ball size)
    var sizeModelSpeedMph: Double?
    var sizeModelLaunchDeg: Double?
    var startDirectionAwayDeg: Double?   // + = away from camera
    var startDirectionLabel: String?     // e.g. "1.7° RIGHT"
    // Scale / setup
    var addressDistanceM: Double
    var mmPerPixelAtBall: Double
    var pixelSpeedPxPerFrame: Double = 0
    var cameraPitchDeg: Double
    var cameraRollDeg: Double
    var usedGravity: Bool
}

/// Pixel track → metric launch conditions.
///
/// Camera model: pinhole with intrinsics K; ray(u,v) = ((u−cx)/fx, (v−cy)/fy, 1) in camera coordinates
/// (+x right, +y down, +z forward). Lens distortion is ignored (small near the centre of the main camera).
///
/// PRIMARY: flight-plane model. We assume the camera is face-on, looking roughly perpendicular to the target
/// line. The ball then flies in the vertical plane that contains the address point and whose normal is the
/// camera's horizontal viewing direction. Each ball pixel is intersected with that plane → 3D point → fit
/// velocity. The ball's distance comes from its apparent size at address (known 42.67 mm diameter),
/// averaged over many stationary frames, which is the most accurate size measurement we get.
/// Error sources: aim error vs. the target line (≈1−cos θ; 10° ≈ 1.5 %), radius error (same % in speed).
///
/// EXPERIMENTAL: size model. Depth per frame from the moving ball's apparent size. This is the only
/// single-camera handle on start direction, but blur and small radii make it noisy. Reported, never hidden.
enum LaunchGeometry {
    static let ballRadiusM = 0.042672 / 2.0
    static let mpsToMph = 2.2369362920544

    static func ray(_ u: Double, _ v: Double, _ K: CameraIntrinsics) -> SIMD3<Double> {
        SIMD3((u - K.cx) / K.fx, (v - K.cy) / K.fy, 1)
    }

    /// World "up" in camera coordinates. Falls back to image-up when no motion data is available.
    static func upVector(_ gravityCam: SIMD3<Double>?) -> (up: SIMD3<Double>, fromGravity: Bool) {
        if let g = gravityCam, simd_length(g) > 0.5 { return (-simd_normalize(g), true) }
        return (SIMD3(0, -1, 0), false)
    }

    /// Least-squares velocity of 3D points vs time (independent linear fits per axis).
    static func velocity(_ samples: [(t: Double, p: SIMD3<Double>)]) -> (v: SIMD3<Double>, rms: Double)? {
        let t = samples.map { $0.t }
        guard let fx = LinearFit.fit(t, samples.map { $0.p.x }),
              let fy = LinearFit.fit(t, samples.map { $0.p.y }),
              let fz = LinearFit.fit(t, samples.map { $0.p.z }) else { return nil }
        let rms = (fx.rms * fx.rms + fy.rms * fy.rms + fz.rms * fz.rms).squareRoot()
        return (SIMD3(fx.slope, fy.slope, fz.slope), rms)
    }

    static func computeMetrics(points: [TrackPoint], address: BallObservation, K: CameraIntrinsics,
                               gravityCam: SIMD3<Double>?, awayIsLeft: Bool, notes: inout [String]) -> LaunchMetrics? {
        guard points.count >= 2, address.radius > 0 else { return nil }
        let (up, usedGravity) = upVector(gravityCam)
        if !usedGravity { notes.append("No gravity data — assumed the camera is perfectly level.") }
        let attitude = MotionManager.attitude(gravityCam: -up)

        // Address point in 3D from the known ball size.
        let R = ballRadiusM
        let z0 = K.fx * R / address.radius
        let p0 = ray(address.x, address.y, K) * z0

        // Flight plane: vertical, through p0, normal = horizontal component of the optical axis.
        var n = SIMD3<Double>(0, 0, 1) - up * up.z
        guard simd_length(n) > 0.3 else {
            notes.append("Camera points too steeply up/down for the flight-plane model.")
            return nil
        }
        n = simd_normalize(n)

        let planeSamples: [(t: Double, p: SIMD3<Double>)] = points.map { pt in
            let d = ray(pt.u, pt.v, K)
            let s = simd_dot(n, p0) / simd_dot(n, d)
            return (pt.t, d * s)
        }
        guard let planeFit = velocity(planeSamples) else { return nil }
        let speed = simd_length(planeFit.v)
        guard speed > 0.1 else { return nil }
        let launch = asin(max(-1, min(1, simd_dot(planeFit.v, up) / speed))) * 180 / .pi

        var metrics = LaunchMetrics(
            ballSpeedMph: speed * mpsToMph, ballSpeedMps: speed, launchDeg: launch, planeFitRmsM: planeFit.rms,
            sizeModelSpeedMph: nil, sizeModelLaunchDeg: nil, startDirectionAwayDeg: nil, startDirectionLabel: nil,
            addressDistanceM: simd_length(p0), mmPerPixelAtBall: R * 1000 / address.radius,
            cameraPitchDeg: attitude.pitch, cameraRollDeg: attitude.roll, usedGravity: usedGravity)

        // Experimental size model.
        let sizeSamples: [(t: Double, p: SIMD3<Double>)] = points.map { pt in
            (pt.t, ray(pt.u, pt.v, K) * (K.fx * R / max(pt.radius, 0.5)))
        }
        if points.count >= 3, let sizeFit = velocity(sizeSamples) {
            let s = simd_length(sizeFit.v)
            if s > 0.1 {
                metrics.sizeModelSpeedMph = s * mpsToMph
                metrics.sizeModelLaunchDeg = asin(max(-1, min(1, simd_dot(sizeFit.v, up) / s))) * 180 / .pi
                var targetAxis = simd_normalize(simd_cross(up, n))
                if simd_dot(targetAxis, sizeFit.v) < 0 { targetAxis = -targetAxis }
                let away = atan2(simd_dot(sizeFit.v, n), simd_dot(sizeFit.v, targetAxis)) * 180 / .pi
                metrics.startDirectionAwayDeg = away
                let side = (away > 0) == awayIsLeft ? "LEFT" : "RIGHT"
                metrics.startDirectionLabel = String(format: "%.1f° %@", abs(away), side)
            }
        }
        return metrics
    }
}
