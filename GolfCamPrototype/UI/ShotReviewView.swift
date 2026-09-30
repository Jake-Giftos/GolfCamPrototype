import SwiftUI

/// Frame-by-frame review of the analysed window: the fastest way to see whether the tracker is right.
/// Yellow = address ball, red = rejected candidate, green = tracked ball, blue = fitted path.
struct ShotReviewView: View {
    let record: ShotRecord
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Shot \(record.shotNumber) · \(record.club)").bold()
                if let frame = current {
                    Text(String(format: "frame %ld/%ld · t = %+.2f ms · %ld candidates",
                                index + 1, record.reviewFrames.count, frame.tMs, frame.candidates.count))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)

            if let frame = current {
                GeometryReader { geo in
                    ZStack {
                        Image(decorative: frame.image, scale: 1)
                            .resizable()
                            .interpolation(.none)
                            .aspectRatio(contentMode: .fit)
                        overlay(frame: frame)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }

                HStack {
                    Button { index = max(0, index - 1) } label: { Image(systemName: "chevron.left") }
                    Slider(value: Binding(get: { Double(index) },
                                          set: { index = Int($0.rounded()) }),
                           in: 0...Double(max(record.reviewFrames.count - 1, 1)), step: 1)
                    Button { index = min(record.reviewFrames.count - 1, index + 1) } label: { Image(systemName: "chevron.right") }
                }
                .padding(.horizontal)
            } else {
                Spacer()
                Text("No frames available for this shot.").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.vertical, 8)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onAppear {
            // Start at the trigger frame.
            if let i = record.reviewFrames.firstIndex(where: { $0.id == record.analysis.triggerPosition }) { index = i }
        }
    }

    private var current: ReviewFrame? {
        record.reviewFrames.indices.contains(index) ? record.reviewFrames[index] : nil
    }

    private func overlay(frame: ReviewFrame) -> some View {
        let crop = record.crop
        return Canvas { ctx, size in
            let m = FrameMapper(source: CGSize(width: crop.width, height: crop.height), view: size)
            func pt(_ x: Double, _ y: Double) -> CGPoint { m.toView(x - Double(crop.minX), y - Double(crop.minY)) }
            func circle(_ x: Double, _ y: Double, _ r: Double, _ color: Color, _ width: CGFloat = 2) {
                let c = pt(x, y)
                let rr = CGFloat(r) * m.scale
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr)),
                           with: .color(color), lineWidth: width)
            }

            let a = record.address
            circle(a.x, a.y, a.radius, .yellow, 1)

            if let fit = record.analysis.fit {
                var path = Path()
                let t0 = fit.impactTime
                let t1 = (record.reviewFrames.last?.tMs ?? 0) / 1000
                let p0 = fit.position(at: t0), p1 = fit.position(at: t1)
                path.move(to: pt(p0.x, p0.y))
                path.addLine(to: pt(p1.x, p1.y))
                ctx.stroke(path, with: .color(.blue.opacity(0.6)), lineWidth: 1)
            }
            if let p = frame.predicted {
                circle(Double(p.x), Double(p.y), 2, .blue, 2)
            }
            for c in frame.candidates {
                circle(c.x, c.y, c.radius, c.inlier ? .green : .red, c.inlier ? 2.5 : 1.5)
            }
        }
        .allowsHitTesting(false)
    }
}
