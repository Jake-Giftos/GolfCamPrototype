import Foundation

struct BallObservation: Codable {
    var x: Double          // centre, buffer px
    var y: Double
    var radius: Double     // px, from sub-pixel equator chord
    var area: Int
    var fill: Double       // blob area / bbox area (disc ≈ 0.785)
    var aspect: Double     // bbox width / height
    var meanLuma: Double
    var background: Double // median luma of the search zone
}

/// Classical detection of a stationary white ball inside the placement zone. No ML.
enum BallDetector {
    /// 1. Histogram of the zone → median (background) and 99.9th percentile (ball highlight).
    /// 2. Threshold halfway between them, label bright blobs.
    /// 3. Keep roughly circular blobs of plausible size, refine each to a sub-pixel radius, score, pick best.
    static func findStationaryBall(in img: LumaView, zone: PixelRect, minRadius: Double, maxRadius: Double) -> BallObservation? {
        let rect = zone.clipped(width: img.width, height: img.height)
        guard rect.width > 8, rect.height > 8 else { return nil }

        var hist = [Int](repeating: 0, count: 256)
        var count = 0
        for y in stride(from: rect.minY, to: rect.maxY, by: 2) {
            let row = img.base + y * img.bytesPerRow
            for x in stride(from: rect.minX, to: rect.maxX, by: 2) {
                hist[Int(row[x])] += 1
                count += 1
            }
        }
        func percentile(_ p: Double) -> Int {
            let target = Int(Double(count) * p)
            var acc = 0
            for i in 0..<256 {
                acc += hist[i]
                if acc > target { return i }
            }
            return 255
        }
        let median = percentile(0.5)
        let high = percentile(0.999)
        let contrast = high - median
        guard contrast >= 30 else { return nil }
        let threshold = median + contrast / 2

        var mask = BlobLabeler.brightMask(img, rect: rect, threshold: threshold)
        let minArea = max(8, Int(Double.pi * minRadius * minRadius * 0.4))
        let maxArea = Int(Double.pi * maxRadius * maxRadius * 1.6)
        let blobs = BlobLabeler.label(mask: &mask, rect: rect, luma: img, minArea: minArea, maxArea: maxArea)

        let zoneCx = Double(rect.minX + rect.maxX) / 2
        let zoneCy = Double(rect.minY + rect.maxY) / 2
        let zoneSize = Double(max(rect.width, rect.height))
        var best: (obs: BallObservation, score: Double)?

        for b in blobs {
            let aspect = Double(b.width) / Double(b.height)
            let fill = Double(b.area) / Double(b.width * b.height)
            // A sun-lit ball has a shaded underside and may sit on a tee, so allow some departure from a disc.
            guard aspect > 0.6, aspect < 1.7, fill > 0.45, fill < 0.95 else { continue }
            guard let r = refine(img, blob: b, background: Double(median)) else { continue }
            guard r.radius >= minRadius, r.radius <= maxRadius else { continue }
            let dist = hypot(r.x - zoneCx, r.y - zoneCy) / zoneSize
            let score = (1 - abs(fill - 0.785)) * (1 - min(0.9, abs(log(aspect)))) * b.meanLuma / (1 + 2 * dist)
            if best == nil || score > best!.score {
                best = (BallObservation(x: r.x, y: r.y, radius: r.radius, area: b.area, fill: fill, aspect: aspect,
                                        meanLuma: b.meanLuma, background: Double(median)), score)
            }
        }
        return best?.obs
    }

    /// Sub-pixel radius: for every row of the blob, find the left/right crossings of the level halfway between
    /// ball and background (linear interpolation between pixels). The longest chord (3-row smoothed) is the
    /// equator, i.e. the diameter. Horizontal chords are used because sunlight shades the ball's underside,
    /// which makes vertical extent unreliable.
    ///
    /// This radius sets the metres-per-pixel scale, so any error in it becomes the same % error in ball speed.
    static func refine(_ img: LumaView, blob b: Blob, background: Double) -> (x: Double, y: Double, radius: Double)? {
        let level = (b.meanLuma + background) / 2
        let cx = Int(b.centerX.rounded())
        guard cx > 0, cx < img.width - 1 else { return nil }
        let y0 = max(1, b.minY), y1 = min(img.height - 2, b.maxY)
        guard y0 <= y1 else { return nil }

        var chords: [(y: Int, width: Double, mid: Double)] = []
        for y in y0...y1 {
            let row = img.base + y * img.bytesPerRow
            guard Double(row[cx]) > level else { continue }

            var xl = cx
            while xl > 0 && Double(row[xl - 1]) > level { xl -= 1 }
            guard xl > 0 else { continue }
            let a = Double(row[xl - 1]), c = Double(row[xl])          // a ≤ level < c
            let left = Double(xl - 1) + (level - a) / max(c - a, 1e-6)

            var xr = cx
            while xr < img.width - 1 && Double(row[xr + 1]) > level { xr += 1 }
            guard xr < img.width - 1 else { continue }
            let a2 = Double(row[xr]), c2 = Double(row[xr + 1])        // a2 > level ≥ c2
            let right = Double(xr) + (a2 - level) / max(a2 - c2, 1e-6)

            chords.append((y, right - left, (left + right) / 2))
        }
        guard chords.count >= 3 else { return nil }

        var bestIndex = 1
        var bestWidth = 0.0
        for i in 1..<(chords.count - 1) {
            let w = (chords[i - 1].width + chords[i].width + chords[i + 1].width) / 3
            if w > bestWidth { bestWidth = w; bestIndex = i }
        }
        let eq = chords[bestIndex]
        return (eq.mid, Double(eq.y), bestWidth / 2)
    }
}

/// Pixels of the inner part of the ball at address. While armed, each new frame is compared against this;
/// a large mean absolute difference means the ball left (or something covered it).
struct DiscReference {
    let centerX: Int
    let centerY: Int
    private let dxs: [Int]
    private let dys: [Int]
    private(set) var values: [UInt8]

    init?(view: LumaView, x: Double, y: Double, radius: Double) {
        let r = max(2.0, radius)
        let cx = Int(x.rounded()), cy = Int(y.rounded())
        let ri = Int(r.rounded(.up))
        var dxs: [Int] = [], dys: [Int] = []
        for dy in -ri...ri {
            for dx in -ri...ri where Double(dx * dx + dy * dy) <= r * r {
                let px = cx + dx, py = cy + dy
                guard px >= 0, py >= 0, px < view.width, py < view.height else { continue }
                dxs.append(dx); dys.append(dy)
            }
        }
        guard dxs.count >= 8 else { return nil }
        centerX = cx; centerY = cy
        self.dxs = dxs; self.dys = dys
        values = zip(dxs, dys).map { view.at(cx + $0, cy + $1) }
    }

    func meanAbsDiff(_ v: LumaView) -> Double {
        var sum = 0
        for i in dxs.indices {
            sum += abs(Int(v.at(centerX + dxs[i], centerY + dys[i])) - Int(values[i]))
        }
        return Double(sum) / Double(dxs.count)
    }

    /// Re-baseline slowly to follow gradual light changes while waiting for the swing.
    mutating func refresh(from v: LumaView) {
        for i in dxs.indices { values[i] = v.at(centerX + dxs[i], centerY + dys[i]) }
    }
}
