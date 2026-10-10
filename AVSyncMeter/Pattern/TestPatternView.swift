import AVFoundation
import AVKit
import SwiftUI

struct TestPatternView: View {
    @State private var player: AVPlayer?
    @State private var loopObserver: NSObjectProtocol?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let url = TestPattern.url {
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
                                               description: Text("Run tools/make_test_pattern.sh and add the MP4 to AVSyncMeter/Resources."))
                    }
                    instructions
                }
                .padding()
            }
            .navigationTitle("Test Pattern")
        }
        .onAppear { setUpPlayer() }
    }

    private var patternDescription: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("avsync_1080p60.mp4").font(.headline)
            Text(String(format: "1920x1080, %.0f fps, H.264 + AAC. Black screen; every %.1f s the whole frame turns white for %.0f ms while a %.0f Hz tone plays for %.0f ms. Flash and tone start on the same timestamp.",
                        TestPattern.frameRate, TestPattern.period, TestPattern.flashDuration * 1000,
                        TestPattern.toneFrequency, TestPattern.toneDuration * 1000))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How to use it").font(.headline)
            Text("""
            1. Get the pattern onto the screen under test. Best: Export it and play it from the real source (media player, Apple TV, PC, Blu-ray player via USB) so the whole chain is measured. Quickest: tap the AirPlay button and send it to an Apple TV.
            2. Switch to Measure, aim the back camera at the screen and tap Start.
            3. Read the two numbers: the offset at the phone (what you experience in that seat) and the offset at the screen (with the sound's travel time removed).

            If AirPlay playback stops when measurement starts, the capture session took over the audio session. Play the file from another device instead.
            """)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private func setUpPlayer() {
        guard player == nil, let url = TestPattern.url else { return }
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
