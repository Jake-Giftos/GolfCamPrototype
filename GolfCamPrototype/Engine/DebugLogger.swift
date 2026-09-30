import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Everything needed to re-analyse or audit a shot offline.
struct ShotLog: Codable {
    var shotNumber: Int
    var timestamp: String
    var club: String
    var device: String
    var format: String
    var measuredFPS: Double
    var exposure: CameraManager.ExposureSnapshot?
    var intrinsics: CameraIntrinsics
    var gravityCamera: [Double]?
    var address: BallObservation
    var triggerThreshold: Double
    var triggerMAD: Double
    var targetOnRight: Bool
    var rightHanded: Bool
    var status: String
    var message: String
    var confidence: String
    var frameTimesRelTrigger: [Double]
    var candidates: [TrackCandidate]
    var fit: PixelFit?
    var metrics: LaunchMetrics?
    var notes: [String]
    var analysisMs: Double
}

/// Writes to the app's Documents folder (visible in Files › On My iPhone › GolfCam):
///   shots.csv                      one row per shot, with empty reference columns to fill in at the range
///   Shots/shot-0001.json           full debug log
///   Shots/shot-0001-frames/*.png   optional raw frames (Settings › Save frames)
final class DebugLogger {
    let documents: URL
    let shotsDir: URL
    let csvURL: URL

    init() {
        documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        shotsDir = documents.appendingPathComponent("Shots", isDirectory: true)
        csvURL = documents.appendingPathComponent("shots.csv")
        try? FileManager.default.createDirectory(at: shotsDir, withIntermediateDirectories: true)
    }

    func nextShotNumber() -> Int {
        let n = UserDefaults.standard.integer(forKey: "shotCounter") + 1
        UserDefaults.standard.set(n, forKey: "shotCounter")
        return n
    }

    func save(_ log: ShotLog, frames: [LumaFrame]?) {
        let name = String(format: "shot-%04d", log.shotNumber)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        do {
            let data = try encoder.encode(log)
            try data.write(to: shotsDir.appendingPathComponent("\(name).json"))
        } catch {
            print("[Logger] JSON write failed: \(error)")
        }
        appendCSV(log)

        if let frames {
            let dir = shotsDir.appendingPathComponent("\(name)-frames", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for f in frames {
                guard let img = f.makeImage() else { continue }
                let url = dir.appendingPathComponent(String(format: "frame-%06d.png", f.frameNumber))
                guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
                CGImageDestinationAddImage(dest, img, nil)
                CGImageDestinationFinalize(dest)
            }
        }
    }

    static let csvHeader = "shot,timestamp,club,status,confidence,ball_speed_mph,launch_deg,start_dir_experimental," +
        "size_model_speed_mph,size_model_launch_deg,inliers,rms_px,px_per_frame,mm_per_px,distance_m,measured_fps," +
        "exposure_s,iso,ref_ball_speed_mph,ref_launch_deg,ref_start_dir_deg,ref_device\n"

    private func appendCSV(_ log: ShotLog) {
        func f(_ v: Double?, _ digits: Int = 2) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "" }
        let m = log.metrics
        let fields: [String] = [
            "\(log.shotNumber)", log.timestamp, log.club, log.status, log.confidence,
            f(m?.ballSpeedMph), f(m?.launchDeg), m?.startDirectionLabel ?? "",
            f(m?.sizeModelSpeedMph), f(m?.sizeModelLaunchDeg),
            log.fit.map { "\($0.inlierCount)" } ?? "", f(log.fit?.rmsPx), f(m?.pixelSpeedPxPerFrame), f(m?.mmPerPixelAtBall, 3),
            f(m?.addressDistanceM, 3), f(log.measuredFPS, 1), f(log.exposure?.durationS, 6), f(log.exposure?.iso, 0),
            "", "", "", "",
        ]
        let line = fields.map { $0.contains(",") ? "\"\($0)\"" : $0 }.joined(separator: ",") + "\n"
        do {
            if !FileManager.default.fileExists(atPath: csvURL.path) {
                try Self.csvHeader.write(to: csvURL, atomically: true, encoding: .utf8)
            }
            let handle = try FileHandle(forWritingTo: csvURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            print("[Logger] CSV write failed: \(error)")
        }
    }

    static var deviceModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
