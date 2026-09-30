import Foundation

/// Connected-component statistics accumulated while flood-filling.
struct Blob {
    var area = 0
    var sumX = 0.0, sumY = 0.0
    var sumXX = 0.0, sumYY = 0.0, sumXY = 0.0
    var sumLuma = 0.0
    var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min

    mutating func add(x: Int, y: Int, luma: UInt8) {
        let fx = Double(x), fy = Double(y)
        area += 1
        sumX += fx; sumY += fy
        sumXX += fx * fx; sumYY += fy * fy; sumXY += fx * fy
        sumLuma += Double(luma)
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }

    var centerX: Double { sumX / Double(area) }
    var centerY: Double { sumY / Double(area) }
    var meanLuma: Double { sumLuma / Double(area) }
    var width: Int { maxX - minX + 1 }
    var height: Int { maxY - minY + 1 }

    /// Standard deviations along the principal axes (major ≥ minor), from the second moments.
    /// A motion-blurred ball is a "stadium": its minor axis still reflects the true ball diameter.
    var principalStd: (major: Double, minor: Double) {
        let n = Double(area)
        let mx = centerX, my = centerY
        let a = sumXX / n - mx * mx
        let b = sumXY / n - mx * my
        let c = sumYY / n - my * my
        let half = (a + c) / 2
        let disc = max(0, half * half - (a * c - b * b)).squareRoot()
        return ((half + disc).squareRoot(), max(0, half - disc).squareRoot())
    }
}

enum BlobLabeler {
    /// 8-connected labelling of non-zero pixels in `mask` (row-major, size rect.width × rect.height).
    /// Returned coordinates are in full-buffer space. Components larger than `maxArea` are consumed but dropped.
    /// The mask is cleared in the process.
    static func label(mask: inout [UInt8], rect: PixelRect, luma: LumaView, minArea: Int, maxArea: Int) -> [Blob] {
        let w = rect.width, h = rect.height
        guard w > 0, h > 0, mask.count == w * h else { return [] }
        var blobs: [Blob] = []
        var stack: [Int] = []
        stack.reserveCapacity(4096)

        mask.withUnsafeMutableBufferPointer { m in
            for start in 0..<(w * h) where m[start] != 0 {
                var blob = Blob()
                var tooBig = false
                m[start] = 0
                stack.append(start)
                while let idx = stack.popLast() {
                    let lx = idx % w, ly = idx / w
                    if !tooBig {
                        let gx = lx + rect.minX, gy = ly + rect.minY
                        blob.add(x: gx, y: gy, luma: luma.at(gx, gy))
                        if blob.area > maxArea { tooBig = true }
                    }
                    for dy in -1...1 {
                        let ny = ly + dy
                        if ny < 0 || ny >= h { continue }
                        for dx in -1...1 {
                            let nx = lx + dx
                            if nx < 0 || nx >= w { continue }
                            let ni = ny * w + nx
                            if m[ni] != 0 { m[ni] = 0; stack.append(ni) }
                        }
                    }
                }
                if !tooBig && blob.area >= minArea { blobs.append(blob) }
            }
        }
        return blobs
    }

    /// Pixels brighter than `threshold` inside `rect`.
    static func brightMask(_ img: LumaView, rect: PixelRect, threshold: Int) -> [UInt8] {
        let w = rect.width, h = rect.height
        var mask = [UInt8](repeating: 0, count: max(0, w * h))
        guard w > 0, h > 0 else { return mask }
        mask.withUnsafeMutableBufferPointer { m in
            for y in 0..<h {
                let row = img.base + (y + rect.minY) * img.bytesPerRow + rect.minX
                let out = y * w
                for x in 0..<w where Int(row[x]) > threshold { m[out + x] = 1 }
            }
        }
        return mask
    }

    /// Three-frame (double) differencing: a pixel is "moving object in the current frame" only if it differs
    /// from BOTH the previous and the next frame. This isolates where the ball is in `cur` and suppresses
    /// where it was (prev) and where it will be (next). Requires the ball to move ≳ 1 diameter per frame,
    /// i.e. roughly > 23 mph at 240 fps — true for any full swing.
    static func motionMask(prev: LumaView, cur: LumaView, next: LumaView, rect: PixelRect, threshold: Int) -> [UInt8] {
        let w = rect.width, h = rect.height
        var mask = [UInt8](repeating: 0, count: max(0, w * h))
        guard w > 0, h > 0 else { return mask }
        mask.withUnsafeMutableBufferPointer { m in
            for y in 0..<h {
                let gy = y + rect.minY
                let p = prev.base + gy * prev.bytesPerRow + rect.minX
                let c = cur.base + gy * cur.bytesPerRow + rect.minX
                let n = next.base + gy * next.bytesPerRow + rect.minX
                let out = y * w
                for x in 0..<w {
                    let cv = Int(c[x])
                    if abs(cv - Int(p[x])) > threshold && abs(cv - Int(n[x])) > threshold { m[out + x] = 1 }
                }
            }
        }
        return mask
    }
}
