import SwiftUI

@main
struct GolfCamPrototypeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        }
    }
}

/// Owns and wires the long-lived services.
final class AppModel: ObservableObject {
    let motion = MotionManager()
    let camera = CameraManager()
    let engine: ShotEngine

    init() {
        engine = ShotEngine(motion: motion, videoQueue: camera.videoQueue)
        engine.camera = camera
        camera.engine = engine
    }

    func start() {
        motion.start()
        camera.start()
    }
}
