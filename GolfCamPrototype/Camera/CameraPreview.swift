import AVFoundation
import SwiftUI

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

/// Live preview. Uses aspect-fit and no rotation so the on-screen image is exactly the analysed buffer,
/// which lets overlays use a simple scale + offset (see FrameMapper).
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        applyRotation(view)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        // The connection only exists once the session has an input, so keep re-applying.
        applyRotation(uiView)
    }

    private func applyRotation(_ view: PreviewView) {
        if let c = view.previewLayer.connection, c.videoRotationAngle != 0, c.isVideoRotationAngleSupported(0) {
            c.videoRotationAngle = 0
        }
    }
}

/// Maps between analysed-buffer pixel coordinates and an aspect-fit view of that buffer.
struct FrameMapper {
    let source: CGSize
    let view: CGSize

    var scale: CGFloat {
        guard source.width > 0, source.height > 0 else { return 1 }
        return min(view.width / source.width, view.height / source.height)
    }
    var offset: CGPoint {
        CGPoint(x: (view.width - source.width * scale) / 2, y: (view.height - source.height * scale) / 2)
    }
    func toView(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: offset.x + CGFloat(x) * scale, y: offset.y + CGFloat(y) * scale)
    }
    func toSource(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - offset.x) / scale, y: (p.y - offset.y) / scale)
    }
}
