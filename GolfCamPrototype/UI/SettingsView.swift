import SwiftUI

struct SettingsView: View {
    @Binding var targetOnRight: Bool
    @Binding var rightHanded: Bool
    @Binding var shutter: Double
    @Binding var saveFrames: Bool
    let camera: CameraManager
    let engine: ShotEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Setup") {
                    Picker("Target on screen", selection: $targetOnRight) {
                        Text("← Left").tag(false)
                        Text("Right →").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Picker("Golfer", selection: $rightHanded) {
                        Text("Right-handed").tag(true)
                        Text("Left-handed").tag(false)
                    }
                    .pickerStyle(.segmented)
                    Button("Reset detection box") { engine.resetZone() }
                }
                Section {
                    Picker("Shutter", selection: $shutter) {
                        Text("1/1000").tag(1000.0)
                        Text("1/2000").tag(2000.0)
                        Text("1/4000").tag(4000.0)
                        Text("1/8000").tag(8000.0)
                    }
                    .pickerStyle(.segmented)
                    Button("Re-meter exposure") { camera.remeter() }
                } header: {
                    Text("Exposure")
                } footer: {
                    Text("Faster shutter = less blur. At 150 mph the ball moves ~17 mm during 1/4000 s. If the image gets too dark, use a slower shutter or re-meter.")
                }
                Section {
                    Toggle("Save raw frames (PNG)", isOn: $saveFrames)
                } header: {
                    Text("Debug")
                } footer: {
                    Text("Files › On My iPhone › GolfCam holds shots.csv, per-shot JSON logs and (optionally) ~26 full-resolution frames per shot.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
