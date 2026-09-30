import SwiftUI

enum Clubs {
    static let all = ["DR", "3W", "5W", "4H", "4I", "5I", "6I", "7I", "8I", "9I", "PW", "GW", "SW", "LW"]
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @AppStorage("club") private var club = "7I"
    @AppStorage("targetOnRight") private var targetOnRight = true
    @AppStorage("rightHanded") private var rightHanded = true
    @AppStorage("shutterDenominator") private var shutter = 4000.0
    @AppStorage("saveFrames") private var saveFrames = false
    @State private var showDebug = true
    @State private var showSettings = false
    @State private var showReview = false

    var body: some View {
        MainScreen(camera: model.camera, engine: model.engine, club: $club, targetOnRight: targetOnRight,
                   showDebug: $showDebug, showSettings: $showSettings, showReview: $showReview)
            .preferredColorScheme(.dark)
            .statusBarHidden()
            .onAppear {
                syncSettings()
                model.camera.shutterDenominator = shutter
                model.start()
            }
            .onChange(of: club) { _, _ in syncSettings() }
            .onChange(of: rightHanded) { _, _ in syncSettings() }
            .onChange(of: saveFrames) { _, _ in syncSettings() }
            .onChange(of: targetOnRight) { _, _ in
                syncSettings()
                model.engine.resetZone()
            }
            .onChange(of: shutter) { _, v in model.camera.shutterDenominator = v }
            .sheet(isPresented: $showSettings) {
                SettingsView(targetOnRight: $targetOnRight, rightHanded: $rightHanded, shutter: $shutter,
                             saveFrames: $saveFrames, camera: model.camera, engine: model.engine)
            }
            .fullScreenCover(isPresented: $showReview) {
                if let shot = model.engine.lastShot {
                    ShotReviewView(record: shot)
                }
            }
    }

    private func syncSettings() {
        model.engine.updateSettings {
            $0.club = club
            $0.targetOnRight = targetOnRight
            $0.rightHanded = rightHanded
            $0.saveFrames = saveFrames
        }
    }
}

struct MainScreen: View {
    @ObservedObject var camera: CameraManager
    @ObservedObject var engine: ShotEngine
    @Binding var club: String
    let targetOnRight: Bool
    @Binding var showDebug: Bool
    @Binding var showSettings: Bool
    @Binding var showReview: Bool

    var body: some View {
        HStack(spacing: 0) {
            GeometryReader { geo in
                ZStack(alignment: .top) {
                    CameraPreview(session: camera.session)
                    overlay(size: geo.size)
                    statusBanner.padding(.top, 8)
                }
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { value in
                    handleTap(value.location, viewSize: geo.size)
                })
            }
            .background(Color.black)

            SidePanel(camera: camera, engine: engine, club: $club, showDebug: $showDebug,
                      showSettings: $showSettings, showReview: $showReview, targetOnRight: targetOnRight)
                .frame(width: 290)
        }
        .background(Color.black)
    }

    /// Tap the ball (or where it will be) to move the detection box there and focus on it.
    private func handleTap(_ location: CGPoint, viewSize: CGSize) {
        let size = engine.bufferSize
        guard size.width > 0 else { return }
        let p = FrameMapper(source: size, view: viewSize).toSource(location)
        guard p.x >= 0, p.y >= 0, p.x < size.width, p.y < size.height else { return }
        engine.setZoneCenter(p)
        camera.focus(atNormalizedPoint: CGPoint(x: p.x / size.width, y: p.y / size.height))
    }

    private func overlay(size: CGSize) -> some View {
        let ballColor: Color = engine.phase == .armed ? .green : .yellow
        return Canvas { ctx, canvasSize in
            let m = FrameMapper(source: engine.bufferSize, view: canvasSize)
            if let z = engine.zone {
                let a = m.toView(Double(z.minX), Double(z.minY))
                let b = m.toView(Double(z.maxX), Double(z.maxY))
                ctx.stroke(Path(CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)),
                           with: .color(.white.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            }
            if let ball = engine.ball {
                let c = m.toView(ball.x, ball.y)
                let r = CGFloat(ball.radius) * m.scale + 4
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                           with: .color(ballColor), lineWidth: 2)
            }
            // Target direction arrow
            let arrowY = canvasSize.height - 20
            let x0 = canvasSize.width / 2 - 50, x1 = canvasSize.width / 2 + 50
            var arrow = Path()
            arrow.move(to: CGPoint(x: x0, y: arrowY))
            arrow.addLine(to: CGPoint(x: x1, y: arrowY))
            let tipX = targetOnRight ? x1 : x0
            let dir: CGFloat = targetOnRight ? -1 : 1
            arrow.move(to: CGPoint(x: tipX + 10 * dir, y: arrowY - 7))
            arrow.addLine(to: CGPoint(x: tipX, y: arrowY))
            arrow.addLine(to: CGPoint(x: tipX + 10 * dir, y: arrowY + 7))
            ctx.stroke(arrow, with: .color(.white.opacity(0.8)), lineWidth: 2)
            ctx.draw(Text("TARGET").font(.caption2.bold()).foregroundColor(.white),
                     at: CGPoint(x: canvasSize.width / 2, y: arrowY - 14))
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private var statusBanner: some View {
        let (text, color): (String, Color) = {
            switch engine.phase {
            case .waitingForCamera: return ("STARTING CAMERA", .gray)
            case .searching: return ("PLACE BALL IN BOX · OR TAP THE BALL", .orange)
            case .settling: return ("BALL DETECTED · HOLD STILL", .yellow)
            case .armed: return ("BALL READY", .green)
            case .capturing, .analyzing: return ("ANALYZING…", .blue)
            case .result: return ("RESULT", .green)
            case .noShot: return (engine.message.isEmpty ? "NO SHOT" : engine.message, .red)
            }
        }()
        return Text(text)
            .font(.headline.weight(.heavy))
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(color.opacity(0.85), in: Capsule())
            .foregroundStyle(.black)
    }
}

struct SidePanel: View {
    @ObservedObject var camera: CameraManager
    @ObservedObject var engine: ShotEngine
    @Binding var club: String
    @Binding var showDebug: Bool
    @Binding var showSettings: Bool
    @Binding var showReview: Bool
    let targetOnRight: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("GOLF MONITOR").font(.headline.weight(.heavy))
                    Spacer()
                    Button { showSettings = true } label: { Image(systemName: "gearshape.fill") }
                }
                HStack {
                    Text("Club").foregroundStyle(.secondary)
                    Spacer()
                    Picker("Club", selection: $club) {
                        ForEach(Clubs.all, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                row("Camera", camera.nominalFPS > 0
                    ? String(format: "%.0f FPS (%.1f measured)", camera.nominalFPS, engine.measuredFPS) : "—")
                row("Ball", engine.ball == nil ? "NOT FOUND" : "DETECTED")
                row("Status", engine.phase.rawValue)

                if let err = camera.errorMessage {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                ForEach(guidance, id: \.self) { line in
                    Label(line, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }

                Divider()
                resultBlock
                Divider()

                Toggle("Debug", isOn: $showDebug)
                if showDebug { debugBlock }
            }
            .padding(12)
        }
        .background(Color(white: 0.08))
    }

    // MARK: Result

    @ViewBuilder private var resultBlock: some View {
        if let shot = engine.lastShot {
            let m = shot.analysis.metrics
            let isCurrent = engine.phase == .result
            VStack(alignment: .leading, spacing: 6) {
                Text(isCurrent ? "SHOT \(shot.shotNumber) · \(shot.club)" : "LAST SHOT \(shot.shotNumber) · \(shot.club)")
                    .font(.caption.bold()).foregroundStyle(.secondary)
                metric("BALL SPEED", m.map { String(format: "%.1f MPH", $0.ballSpeedMph) } ?? "—")
                metric("LAUNCH", m.map { String(format: "%.1f°", $0.launchDeg) } ?? "—")
                metric("START DIRECTION · EXPERIMENTAL", m?.startDirectionLabel ?? "—", small: true)
                metric("CARRY", "--- yd", small: true)
                if shot.analysis.status != .measured {
                    Text(shot.analysis.message).font(.caption).foregroundStyle(.red)
                }
                if let fit = shot.analysis.fit {
                    Text(String(format: "Confidence %@ · %ld frames · %.2f px rms",
                                shot.analysis.confidence, fit.inlierCount, fit.rmsPx))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(shot.analysis.notes, id: \.self) { note in
                    Text("• " + note).font(.caption2).foregroundStyle(.orange)
                }
                HStack {
                    Button("NEW SHOT") { engine.newShot() }
                        .buttonStyle(.borderedProminent).tint(.green)
                    Button("REVIEW") { showReview = true }
                        .buttonStyle(.bordered)
                }
            }
            .opacity(isCurrent ? 1 : 0.6)
        } else {
            Text("No shots yet").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Debug

    private var debugBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            debug("Format", camera.formatDescription)
            debug("Exposure", camera.exposureDescription)
            debug("Dropped", "\(engine.droppedFrames)")
            debug("Intrinsics", engine.intrinsicsSummary)
            if let a = engine.attitude {
                debug("Pitch/Roll", String(format: "%.1f° / %.1f°", a.pitch, a.roll))
            }
            if let b = engine.ball {
                debug("Ball px", String(format: "(%.1f, %.1f) r=%.2f", b.x, b.y, b.radius))
                debug("Scale", String(format: "%.2f mm/px", LaunchGeometry.ballRadiusM * 1000 / b.radius))
                debug("Contrast", String(format: "ball %.0f / bg %.0f", b.meanLuma, b.background))
            }
            debug("Trigger", String(format: "diff %.1f / thr %.1f", engine.discMAD, engine.triggerThreshold))
            if let shot = engine.lastShot {
                let a = shot.analysis
                debug("Analysis", String(format: "%.0f ms · %ld cands", a.analysisMs, a.candidates.count))
                if let m = a.metrics {
                    debug("Px speed", String(format: "%.1f px/frame", m.pixelSpeedPxPerFrame))
                    debug("Distance", String(format: "%.2f m to ball", m.addressDistanceM))
                    if let s = m.sizeModelSpeedMph, let l = m.sizeModelLaunchDeg {
                        debug("Size model", String(format: "%.1f mph · %.1f°", s, l))
                    }
                }
                if let f = a.fit {
                    debug("Impact", String(format: "t=%.2f ms · miss %.1f px", f.impactTime * 1000, f.impactMissPx))
                }
            }
            ShareLink(item: engine.logger.csvURL) {
                Label("Export shots.csv", systemImage: "square.and.arrow.up")
            }
            .font(.caption)
            .padding(.top, 4)
        }
        .font(.system(.caption2, design: .monospaced))
    }

    // MARK: Guidance

    /// Setup hints for the recommended face-on position.
    private var guidance: [String] {
        var out: [String] = []
        if let a = engine.attitude {
            if abs(a.roll) > 3 { out.append(String(format: "Level the phone (tilted %.0f°)", a.roll)) }
            if a.pitch < -25 { out.append(String(format: "Camera aims %.0f° down — aim more level at the ball", -a.pitch)) }
            if a.pitch > 10 { out.append("Camera aims upward — lower it toward the ball") }
        }
        guard engine.phase != .result else { return out }
        if let b = engine.ball {
            if b.radius < 9 { out.append(String(format: "Ball is small (%.0f px) — move phone closer", b.radius)) }
            if b.radius > 28 { out.append(String(format: "Ball is large (%.0f px) — move phone back", b.radius)) }
            let w = engine.bufferSize.width
            if w > 0 {
                let frac = b.x / Double(w)
                if targetOnRight && frac > 0.45 {
                    out.append("Ball is too far toward the target — rotate the phone toward the target so the ball sits in the left third")
                } else if !targetOnRight && frac < 0.55 {
                    out.append("Ball is too far toward the target — rotate the phone toward the target so the ball sits in the right third")
                }
            }
        } else if engine.phase == .searching {
            out.append("Ball not in the box — place it there, or tap the ball on screen")
        }
        return out
    }

    // MARK: Row helpers

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).bold()
        }
        .font(.subheadline)
    }

    private func metric(_ title: String, _ value: String, small: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption2.bold()).foregroundStyle(.secondary)
            Text(value).font(small ? .title3.bold() : .largeTitle.weight(.heavy)).monospacedDigit()
        }
    }

    private func debug(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
            Text(v)
        }
    }
}
