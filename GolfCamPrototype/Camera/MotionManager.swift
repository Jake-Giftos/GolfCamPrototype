import CoreMotion
import Foundation
import simd

/// Provides a smoothed gravity vector so launch angle is measured against true vertical,
/// regardless of how the tripod head is tilted.
final class MotionManager {
    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var gravity = SIMD3<Double>(0, 0, 0)
    private var hasGravity = false

    func start() {
        guard manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let m = motion else { return }
            let g = SIMD3<Double>(m.gravity.x, m.gravity.y, m.gravity.z)
            self.lock.lock()
            // Light low-pass: the phone is on a tripod, so we want the static tilt, not vibration.
            self.gravity = self.hasGravity ? self.gravity * 0.8 + g * 0.2 : g
            self.hasGravity = true
            self.lock.unlock()
        }
    }

    /// Gravity (≈ unit length) expressed in the camera frame of the native sensor buffer:
    /// +x = image right, +y = image down, +z = out through the rear lens.
    ///
    /// CoreMotion device axes: +x right edge, +y top edge, +z out of the screen (portrait).
    /// The rear sensor buffer is landscape: image right = device −y, image down = device −x, and the
    /// rear camera looks along device −z. Those axes are fixed to the phone body, so this mapping holds
    /// however the phone is mounted.
    var gravityInCamera: SIMD3<Double>? {
        lock.lock(); defer { lock.unlock() }
        guard hasGravity else { return nil }
        return SIMD3(-gravity.y, -gravity.x, -gravity.z)
    }

    /// pitch > 0 means the camera looks upward; roll is the tilt of the image horizon (0 = level).
    static func attitude(gravityCam g: SIMD3<Double>) -> (pitch: Double, roll: Double) {
        let up = -simd_normalize(g)
        let pitch = asin(max(-1, min(1, up.z))) * 180 / .pi
        let roll = atan2(up.x, -up.y) * 180 / .pi
        return (pitch, roll)
    }
}
