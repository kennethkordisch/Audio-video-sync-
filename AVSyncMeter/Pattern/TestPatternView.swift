import AVFoundation
import AVKit
import SwiftUI

struct TestPatternView: View {
    @AppStorage(AppSettings.Key.patternFrameRate) private var patternFrameRate = TestPattern.defaultFrameRate.fps
    @State private var player: AVPlayer?
    @State private var loopObserver: NSObjectProtocol?

    private var rate: PatternFrameRate { TestPattern.frameRate(matching: patternFrameRate) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Frame rate", selection: $patternFrameRate) {
                        ForEach(TestPattern.frameRates) { r in
                            Text("\(r.label) fps").tag(r.fps)
                        }
                    }
                    .pickerStyle(.menu)

                    if let url = TestPattern.url(for: rate) {
                        VideoPlayer(player: player)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .background(Color.black)
                            .clipShape(RoundedRectangle(cornerRadius: 12))

                        HStack(spacing: 12) {
                            Button { play() } label: { Label("Play", systemImage: "play.fill") }
                                .buttonStyle(.borderedProminent)
                            Button { player?.pause() } label: { Label("Pause", systemImage: "pause.fill") }
                                .buttonStyle(.bordered)
                            AirPlayButton()
                                .frame(width: 44, height: 44)
                            Spacer()
                            ShareLink(item: url) {
                                Label("Export", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.bordered)
                        }

                        patternDescription
                    } else {
                        ContentUnavailableView("Test pattern missing",
                                               systemImage: "film",
                                               description: Text("\(TestPattern.fileName(for: rate)) is not in the app bundle. Run tools/make_test_pattern.sh and add it to AVSyncMeter/Resources."))
                    }
                    instructions
                }
                .padding()
            }
            .navigationTitle("Test Pattern")
        }
        .onAppear { rebuildPlayer() }
        .onChange(of: patternFrameRate) { _, _ in rebuildPlayer() }
    }

    private var patternDescription: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(TestPattern.fileName(for: rate)).font(.headline)
            Text(String(format: "1920x1080 at %@ fps, 60 s, H.264 + AAC. Black screen; every %d frames (%.3f s) the whole frame turns white for %d frames while a %.0f Hz tone plays for %.0f ms. The first white frame and the first tone sample share the same timestamp, on a frame boundary.",
                        rate.label, TestPattern.periodFrames(rate),
                        Double(TestPattern.periodFrames(rate)) / rate.fps,
                        TestPattern.flashFrames(rate),
                        TestPattern.toneFrequency, TestPattern.toneDuration * 1000))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Using it with Media Composer").font(.headline)
            Text("""
            1. Export this file (AirDrop or Files) and link or import it into a bin in a project at the same frame rate; or render the DNxHR MXF variant with tools/make_test_pattern.sh -m for a native Avid clip (use -d 1800 for a 30 min drift clip). Put it in a sequence and play out through the monitor and speakers you want to check.
            2. In Measure, aim the back camera at the monitor and tap Start. Results are shown in ms and in frames at the project rate.
            3. Compare desktop playback with hardware I/O, and with and without any output delay setting, to see what each stage adds.

            For a quick check without Avid, tap the AirPlay button to send the file to an Apple TV. If AirPlay stops when measurement starts, play from another device instead.
            """)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private func rebuildPlayer() {
        if let loopObserver {
            NotificationCenter.default.removeObserver(loopObserver)
            self.loopObserver = nil
        }
        player?.pause()
        player = nil
        guard let url = TestPattern.url(for: rate) else { return }
        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.allowsExternalPlayback = true
        newPlayer.usesExternalPlaybackWhileExternalScreenIsActive = true
        newPlayer.actionAtItemEnd = .none
        loopObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                              object: item,
                                                              queue: .main) { _ in
            newPlayer.seek(to: .zero)
            newPlayer.play()
        }
        player = newPlayer
    }

    private func play() {
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playback, mode: .moviePlayback, options: [])
        try? audioSession.setActive(true)
        player?.play()
    }
}

/// System AirPlay route picker.
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        view.tintColor = .label
        view.activeTintColor = .systemBlue
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
