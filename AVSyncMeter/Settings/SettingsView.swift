import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.Key.screenDiagonalInches) private var screenDiagonalInches = 65.0
    @AppStorage(AppSettings.Key.roomTemperatureC) private var roomTemperatureC = 20.0
    @AppStorage(AppSettings.Key.useManualDistance) private var useManualDistance = false
    @AppStorage(AppSettings.Key.manualDistanceMeters) private var manualDistanceMeters = 3.0
    @AppStorage(AppSettings.Key.useExposureMidpoint) private var useExposureMidpoint = true
    @AppStorage(AppSettings.Key.cameraTimestampOffsetMs) private var cameraTimestampOffsetMs = 0.0
    @AppStorage(AppSettings.Key.minFlashContrast) private var minFlashContrast = 12.0
    @AppStorage(AppSettings.Key.targetEventCount) private var targetEventCount = 20

    var body: some View {
        NavigationStack {
            Form {
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
                    Stepper("Stop after \(targetEventCount) events", value: $targetEventCount, in: 3...120)
                    numberField("Minimum flash contrast (0-255)", value: $minFlashContrast)
                } header: {
                    Text("Measurement")
                } footer: {
                    Text("Each event is one flash/beep pair, 2 s apart. 20 events take about 40 s. Lower the contrast threshold if a dim projector is not detected; raise it if room light causes false flashes.")
                }

                Section {
                    Toggle("Time frames at exposure midpoint", isOn: $useExposureMidpoint)
                    numberField("Extra camera offset (ms)", value: $cameraTimestampOffsetMs)
                } header: {
                    Text("Camera timing (advanced)")
                } footer: {
                    Text("Camera frame timestamps mark the start of exposure; adding half the exposure time centres them. At 240 fps this is at most 2 ms. The extra offset is added to every frame time and is for calibrating against a reference if you have one. Positive values make the reported audio lag larger.")
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
