import CoreGraphics
import CoreVideo
import Foundation

/// Read-only view of an 8-bit luma (Y) plane. All vision code works on luma only: a white ball against
/// grass/mat/sky is a brightness problem, and luma is the plane the camera gives us for free.
struct LumaView {
    let base: UnsafePointer<UInt8>
    let width: Int
    let height: Int
    let bytesPerRow: Int

    @inline(__always) func at(_ x: Int, _ y: Int) -> UInt8 { base[y * bytesPerRow + x] }
}

extension LumaView {
    /// Plane 0 of a bi-planar 4:2:0 buffer. Caller must hold CVPixelBufferLockBaseAddress for the view's lifetime.
    init?(lockedPixelBuffer pb: CVPixelBuffer) {
        guard CVPixelBufferGetPlaneCount(pb) >= 1, let src = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
        self.init(base: UnsafePointer(src.assumingMemoryBound(to: UInt8.self)),
                  width: CVPixelBufferGetWidthOfPlane(pb, 0),
                  height: CVPixelBufferGetHeightOfPlane(pb, 0),
                  bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pb, 0))
    }
}

/// Half-open integer rectangle [minX, maxX) × [minY, maxY) in buffer pixels.
struct PixelRect: Codable, Equatable {
    var minX: Int
    var minY: Int
    var maxX: Int
    var maxY: Int

    var width: Int { maxX - minX }
    var height: Int { maxY - minY }
    var isEmpty: Bool { width <= 0 || height <= 0 }

    func clipped(width w: Int, height h: Int) -> PixelRect {
        PixelRect(minX: max(0, minX), minY: max(0, minY), maxX: min(w, maxX), maxY: min(h, maxY))
    }

    static func centered(x: Double, y: Double, halfSize: Double) -> PixelRect {
        PixelRect(minX: Int(x - halfSize), minY: Int(y - halfSize), maxX: Int(x + halfSize), maxY: Int(y + halfSize))
    }
}

/// A copied luma frame. Copies are required because the camera's buffer pool is small; holding
/// CVPixelBuffers for a rolling window would starve capture and drop frames.
final class LumaFrame {
    let width: Int
    let height: Int
    let pixels: UnsafeMutablePointer<UInt8>
    var timestamp: Double = 0      // CMSampleBuffer presentation time, seconds
    var frameNumber: Int = 0       // engine's running frame counter

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = .allocate(capacity: width * height)
        pixels.initialize(repeating: 0, count: width * height)
    }

    deinit { pixels.deallocate() }

    var view: LumaView { LumaView(base: UnsafePointer(pixels), width: width, height: height, bytesPerRow: width) }

    /// Copies the Y plane (≈2 MB at 1080p, well under a millisecond). Caller must have locked the base address.
    @discardableResult
    func copyLuma(from pb: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetWidthOfPlane(pb, 0) == width,
              CVPixelBufferGetHeightOfPlane(pb, 0) == height,
              let src = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return false }
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let s = src.assumingMemoryBound(to: UInt8.self)
        if bpr == width {
            memcpy(pixels, s, width * height)
        } else {
            for y in 0..<height { memcpy(pixels + y * width, s + y * bpr, width) }
        }
        return true
    }

    /// Grayscale CGImage of a crop (for the review screen and PNG export).
    func makeImage(crop: PixelRect? = nil) -> CGImage? {
        let r = (crop ?? PixelRect(minX: 0, minY: 0, maxX: width, maxY: height)).clipped(width: width, height: height)
        guard !r.isEmpty else { return nil }
        var data = Data(count: r.width * r.height)
        data.withUnsafeMutableBytes { raw in
            guard let dst = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for y in 0..<r.height {
                memcpy(dst + y * r.width, pixels + (r.minY + y) * width + r.minX, r.width)
            }
        }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: r.width, height: r.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: r.width,
                       space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Fixed-size rolling buffer of preallocated frames: the "keep ~0.1 s before and ~0.2 s after impact" window.
final class FrameRing {
    let capacity: Int
    let width: Int
    let height: Int
    private let frames: [LumaFrame]
    private var next = 0
    private(set) var filled = 0

    init(capacity: Int, width: Int, height: Int) {
        self.capacity = capacity
        self.width = width
        self.height = height
        frames = (0..<capacity).map { _ in LumaFrame(width: width, height: height) }
    }

    /// The slot to write next. Call `commit()` after filling it.
    func nextSlot() -> LumaFrame { frames[next] }

    func commit() {
        next = (next + 1) % capacity
        filled = min(filled + 1, capacity)
    }

    func reset() {
        next = 0
        filled = 0
    }

    /// Oldest → newest.
    func ordered() -> [LumaFrame] {
        if filled < capacity { return Array(frames[0..<filled]) }
        return Array(frames[next...] + frames[..<next])
    }
}
