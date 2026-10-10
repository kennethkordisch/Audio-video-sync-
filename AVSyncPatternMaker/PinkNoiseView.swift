import SwiftUI

struct PinkNoiseView: View {
    @Bindable var model: GeneratorModel

    var body: some View {
        Form {
            Section("Layout and levels") {
                Picker("Speaker layout", selection: $model.pinkSpec.layout) {
                    ForEach(PinkLayout.allCases) { l in Text("\(l.rawValue)  (\(l.channels.joined(separator: " ")))").tag(l) }
                }
                Picker("Level per channel", selection: $model.pinkSpec.levelDBFS) {
                    Text("-18 dBFS RMS").tag(-18.0)
                    Text("-20 dBFS RMS (cinema / SMPTE reference)").tag(-20.0)
                    Text("-23 dBFS RMS").tag(-23.0)
                }
                Toggle("Band-limit LFE to 120 Hz", isOn: $model.pinkSpec.lfeLowPass)
            }
            Section("Sequence") {
                Picker("Seconds per channel", selection: $model.pinkSpec.segmentSeconds) {
                    Text("10 s").tag(10.0)
                    Text("20 s").tag(20.0)
                    Text("30 s").tag(30.0)
                }
                Picker("Gap between channels", selection: $model.pinkSpec.gapSeconds) {
                    Text("1 s").tag(1.0)
                    Text("2 s").tag(2.0)
                }
                Stepper("Repeat the sequence \(model.pinkSpec.repeats) time\(model.pinkSpec.repeats == 1 ? "" : "s")", value: $model.pinkSpec.repeats, in: 1...5)
                Toggle("Add an all-channels segment at the end", isOn: $model.pinkSpec.includeAllSegment)
                Text(String(format: "Total %.0f s. Order: %@. The iOS app's Levels tab follows this order and reports the trim per speaker.",
                            model.pinkSpec.durationSeconds, model.pinkSpec.layout.channels.joined(separator: ", ")))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Files") {
                Toggle("Multichannel WAV (24-bit, with channel layout)", isOn: $model.pinkWriteWAV)
                Toggle("QuickTime movie with on-screen channel names (video settings from the Sync pattern tab)", isOn: $model.pinkWriteMovie)
                LabeledContent("Names") {
                    Text("\(model.pinkSpec.baseName).wav / .mov").font(.callout.monospaced()).foregroundStyle(.secondary)
                }
                LabeledContent("Folder") {
                    HStack {
                        Text(model.outputFolder.path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…") { model.chooseFolder() }
                    }
                }
            }
            Section("Progress") {
                ProgressView(value: model.progress)
                Text(model.status).font(.callout)
            }
        }
        .formStyle(.grouped)
    }
}
