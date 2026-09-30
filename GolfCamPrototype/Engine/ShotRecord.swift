import CoreGraphics
import Foundation

struct ReviewFrame: Identifiable {
    let id: Int                 // frame position in the analysed window
    let image: CGImage          // cropped grayscale
    let tMs: Double             // ms relative to trigger frame
    let candidates: [TrackCandidate]
    let predicted: CGPoint?     // fitted path position at this frame (buffer px)
}

struct ShotRecord: Identifiable {
    let id = UUID()
    let shotNumber: Int
    let club: String
    let date: Date
    let analysis: ShotAnalysis
    let address: BallObservation
    let crop: PixelRect         // buffer-space origin/size of review images
    let reviewFrames: [ReviewFrame]
}

enum ReviewBuilder {
    /// Crops frames around the address point and every candidate so the ball is big enough to inspect.
    static func build(frames: [LumaFrame], analysis: ShotAnalysis, address: BallObservation) -> (PixelRect, [ReviewFrame]) {
        guard let first = frames.first, analysis.windowEnd > analysis.windowStart else {
            return (PixelRect(minX: 0, minY: 0, maxX: 0, maxY: 0), [])
        }
        let W = first.width, H = first.height
        let r = address.radius
        var minX = address.x - 6 * r, maxX = address.x + 6 * r
        var minY = address.y - 6 * r, maxY = address.y + 6 * r
        for c in analysis.candidates where c.inlier || analysis.fit == nil {
            minX = min(minX, c.x - 4 * r); maxX = max(maxX, c.x + 4 * r)
            minY = min(minY, c.y - 4 * r); maxY = max(maxY, c.y + 4 * r)
        }
        let crop = PixelRect(minX: Int(minX), minY: Int(minY), maxX: Int(maxX), maxY: Int(maxY)).clipped(width: W, height: H)

        var out: [ReviewFrame] = []
        let tTrig = frames[analysis.triggerPosition].timestamp
        for pos in analysis.windowStart...min(analysis.windowEnd, frames.count - 1) {
            guard let img = frames[pos].makeImage(crop: crop) else { continue }
            let t = frames[pos].timestamp - tTrig
            var predicted: CGPoint?
            if let fit = analysis.fit, t >= fit.impactTime {
                let p = fit.position(at: t)
                predicted = CGPoint(x: p.x, y: p.y)
            }
            out.append(ReviewFrame(id: pos, image: img, tMs: t * 1000,
                                   candidates: analysis.candidates.filter { $0.position == pos },
                                   predicted: predicted))
        }
        return (crop, out)
    }
}
