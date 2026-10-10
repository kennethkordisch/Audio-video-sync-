import SwiftUI

struct ContentView: View {
    @State private var model = GeneratorModel()

    private let durationPresets: [(String, Double)] = [
        ("30 s", 30), ("1 min", 60), ("5 min", 300), ("10 min", 600), ("30 min", 1800), ("60 min", 3600),
    ]

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Form {
                Section("Output") {
                    LabeledContent("Folder") {
                        HStack {
                            Text(model.outputFolder.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                            Button("Choose…") { model.chooseFolder() }
                        }
                    }
                    LabeledContent("File name") {
                        Text(model.allFrameRates ? "avsync_\(model.spec.resolution.height)p<rate>_\(model.spec.videoCodec.fileTag).\(model.spec.fileExtension)" : model.spec.fileName)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Estimated size") {
                        Text(model.estimatedFileSizeText).foregroundStyle(.secondary)
                    }
                }

                Section("Format") {
                    Picker("Frame rate", selection: $model.spec.frameRate) {
                        ForEach(FrameRate.all) { rate in Text("\(rate.label) fps").tag(rate) }
                    }
                    .disabled(model.allFrameRates)
                    Toggle("Render every frame rate (8 files)", isOn: $model.allFrameRates)
                    Picker("Resolution", selection: $model.spec.resolution) {
                        ForEach(Resolution.all) { r in Text(r.label).tag(r) }
                    }
                    Picker("Video codec", selection: $model.spec.videoCodec) {
                        ForEach(VideoCodec.allCases) { c in Text(c.rawValue).tag(c) }
                    }
                    Picker("Audio", selection: $model.spec.audioFormat) {
                        ForEach(AudioFormat.allCases) { a in Text(a.rawValue).tag(a) }
                    }
                    HStack {
                        Picker("Duration", selection: $model.spec.durationSeconds) {
                            ForEach(durationPresets, id: \.1) { preset in Text(preset.0).tag(preset.1) }
                        }
                        TextField("s", value: $model.spec.durationSeconds, format: .number)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                        Text("s").foregroundStyle(.secondary)
                    }
                }

                Section("Pattern") {
                    Picker("Event every", selection: $model.spec.periodSeconds) {
                        Text("1 s").tag(1.0)
                        Text("2 s").tag(2.0)
                        Text("3 s").tag(3.0)
                        Text("5 s").tag(5.0)
                    }
                    Stepper("White flash: \(model.spec.flashFrames) frame\(model.spec.flashFrames == 1 ? "" : "s") (\(flashMs) ms)",
                            value: $model.spec.flashFrames, in: 1...6)
                    Picker("Tone", selection: $model.spec.toneFrequency) {
                        Text("500 Hz").tag(500.0)
                        Text("1 kHz").tag(1000.0)
                        Text("2 kHz").tag(2000.0)
                    }
                    Picker("Tone length", selection: $model.spec.toneDurationMs) {
                        Text("20 ms").tag(20.0)
                        Text("50 ms").tag(50.0)
                        Text("100 ms").tag(100.0)
                    }
                    Picker("Tone level", selection: $model.spec.toneLevelDBFS) {
                        Text("-3 dBFS").tag(-3.0)
                        Text("-6 dBFS").tag(-6.0)
                        Text("-12 dBFS").tag(-12.0)
                        Text("-20 dBFS").tag(-20.0)
                    }
                    Picker("Channels", selection: $model.spec.channelMode) {
                        ForEach(ChannelMode.allCases) { m in Text(m.rawValue).tag(m) }
                    }
                    Toggle("Dim caption with event counter", isOn: $model.spec.showCaption)
                    Toggle("Burn in timecode and frame number (non-drop)", isOn: $model.spec.burnInTimecode)
                    Text("Events start at frame \(model.spec.firstEventFrame) and repeat every \(model.spec.periodFrames) frames; the tone starts on the first white frame's timestamp. Period and lead-in are rounded to whole frames so 23.976 and 29.97 files carry no sub-frame offset.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Avid DNxHR MXF") {
                    if model.ffmpegURL != nil {
                        Toggle("Also write DNxHR OP1a MXF with 24-bit PCM", isOn: $model.alsoDNxHR)
                        Picker("Flavour", selection: $model.dnxFlavour) {
                            ForEach(DNxHRFlavour.allCases) { f in Text(f.rawValue).tag(f) }
                        }
                        .disabled(!model.alsoDNxHR)
                        Text("Transcoded from the file above with ffmpeg (\(model.ffmpegDescription)). Use a PCM audio setting so the MXF does not inherit AAC encoder smear.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("ffmpeg is not bundled in this build and was not found in Homebrew. Build again with network access (the Bundle ffmpeg phase fetches it), or brew install ffmpeg. ProRes and H.264 need nothing extra.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Progress") {
                    ProgressView(value: model.progress)
                    Text(model.status).font(.callout)
                    if !model.log.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(model.log.enumerated()), id: \.offset) { entry in
                                    Text(entry.element).font(.caption.monospaced())
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 90)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Reveal in Finder") { model.revealOutputs() }
                Spacer()
                if model.isRunning {
                    Button("Cancel") { model.cancel() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Generate") { model.generate() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
    }

    private var flashMs: Int {
        Int((Double(model.spec.flashFrames) / model.spec.frameRate.fps * 1000).rounded())
    }
}
