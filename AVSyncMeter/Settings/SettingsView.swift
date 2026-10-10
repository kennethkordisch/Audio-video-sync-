import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.Key.patternFrameRate) private var patternFrameRate = TestPattern.defaultFrameRate.fps
    @AppStorage(AppSettings.Key.screenDiagonalInches) private var screenDiagonalInches = 65.0
    @AppStorage(AppSettings.Key.roomTemperatureC) private var roomTemperatureC = 20.0
    @AppStorage(AppSettings.Key.useManualDistance) private var useManualDistance = false
    @AppStorage(AppSettings.Key.manualDistanceMeters) private var manualDistanceMeters = 3.0
    @AppStorage(AppSettings.Key.useExposureMidpoint) private var useExposureMidpoint = true
    @AppStorage(AppSettings.Key.cameraTimestampOffsetMs) private var cameraTimestampOffsetMs = 0.0
    @AppStorage(AppSettings.Key.minFlashContrast) private var minFlashContrast = 12.0
    @AppStorage(AppSettings.Key.targetEventCount) private var targetEventCount = 20
    @AppStorage(AppSettings.Key.driftMode) private var driftMode = false
    @AppStorage(AppSettings.Key.driftDurationMinutes) private var driftDurationMinutes = 5
    @AppStorage(AppSettings.Key.channelIDTones) private var channelIDTones = false
    @AppStorage(AppSettings.Key.readCaption) private var readCaption = true

    private var selectedRate: PatternFrameRate { TestPattern.frameRate(matching: patternFrameRate) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Frame rate", selection: $patternFrameRate) {
                        ForEach(TestPattern.frameRates) { rate in
                            Text("\(rate.label) fps").tag(rate.fps)
                        }
                    }
                } header: {
                    Text("Project frame rate")
                } footer: {
                    Text(String(format: "Match your Media Composer project. The Test Pattern tab plays and exports the %@ fps file (events every %d frames, %d white frames), and every result is also shown in frames: one frame is %.2f ms.",
                                selectedRate.label, TestPattern.periodFrames(selectedRate),
                                TestPattern.flashFrames(selectedRate), selectedRate.frameDuration * 1000))
                }

                Section {
                    Toggle("Drift mode (timed run)", isOn: $driftMode)
                    if driftMode {
                        Stepper("Run for \(driftDurationMinutes) min", value: $driftDurationMinutes, in: 1...60)
                    } else {
                        Stepper("Stop after \(targetEventCount) events", value: $targetEventCount, in: 3...1800)
                    }
                    numberField("Minimum flash contrast (0-255)", value: $minFlashContrast)
                    Toggle("Channel-ID tones (L = 1 kHz, R = 1.6 kHz)", isOn: $channelIDTones)
                    Toggle("Read event number from the caption (OCR)", isOn: $readCaption)
                } header: {
                    Text("Measurement")
                } footer: {
                    Text(driftMode
                         ? "Drift mode keeps measuring for the chosen time and fits a straight line through offset vs. time. A 0.1% clock mismatch (23.976 vs 24, or 48 vs 48.048 kHz) shows up as 60 ms per minute. Use a long pattern file for this: the bundled ones are 60 s, so render one with tools/make_test_pattern.sh -d 1800 and play it from the source under test; the phone's own looping player would add a jump at every loop."
                         : "Each event is one flash/beep pair, 2 s apart; 20 events take about 40 s. Lower the contrast threshold if a dim projector is not detected; raise it if room light causes false flashes. Channel-ID tones match the Mac app's \"Alternate L / R\" pattern and give a separate offset per channel. Caption reading grabs one frame after each flash and OCRs the dim event counter; it needs a reasonably large, bright screen in the frame.")
                }

                Section {
                    Toggle("Enter distance manually", isOn: $useManualDistance)
                    if useManualDistance {
                        numberField("Distance to screen (m)", value: $manualDistanceMeters)
                    }
                    numberField("Screen diagonal (inches)", value: $screenDiagonalInches)
                    numberField("Room temperature (°C)", value: $roomTemperatureC)
                } header: {
                    Text("Distance and sound travel")
                } footer: {
                    Text(String(format: "LiDAR is used when available (up to about 5 m). Otherwise the screen diagonal and the camera's focal length give the distance from how big the flash appears. Speed of sound at this temperature: %.0f m/s, i.e. %.2f ms per metre.",
                                Acoustics.speedOfSound(celsius: roomTemperatureC),
                                1000 / Acoustics.speedOfSound(celsius: roomTemperatureC)))
                }

                Section {
                    Toggle("Time frames at exposure midpoint", isOn: $useExposureMidpoint)
                    numberField("Camera offset (ms)", value: $cameraTimestampOffsetMs)
                    if cameraTimestampOffsetMs != 0 {
                        Button("Reset camera offset to 0") { cameraTimestampOffsetMs = 0 }
                    }
                } header: {
                    Text("Camera timing (advanced)")
                } footer: {
                    Text("Camera frame timestamps mark the start of exposure; adding half the exposure time centres them. At 240 fps this is at most 2 ms. The camera offset is the phone's own camera-vs-microphone bias; set it with the Calibrate mode on the Measure tab against a chain you trust, or type a value. It is added to every frame time, so a positive value makes the reported audio lag smaller.")
                }

                Section("Sign convention") {
                    Text("Offset = beep time minus flash time. Positive: audio lags (arrives after) the picture. Negative: audio leads. Audio lagging is the common case because displays add processing delay; it is also the direction the ear tolerates better.")
                        .font(.footnote)
                }

                Section("How it works") {
                    Text("The back camera runs at the highest frame rate it offers (up to 240 fps) with exposure locked, and the microphone records on the same clock. Each full-screen white flash is timed by interpolating the half-brightness crossing between frames; each 1 kHz beep is timed by a band-pass filter and onset detector that catches the direct sound before room echoes. Flash/beep pairs are matched and the median offset is reported with its spread. Sound travels about 2.9 ms per metre, so the distance to the screen is measured to separate what the playback chain does from what the room adds.")
                        .font(.footnote)
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func numberField(_ title: String, value: Binding<Double>) -> some View {
        LabeledContent(title) {
            TextField(title, value: value, format: .number)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 110)
        }
    }
}
