import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            MeasureView()
                .tabItem { Label("Measure", systemImage: "timer") }
            TestPatternView()
                .tabItem { Label("Test Pattern", systemImage: "play.rectangle") }
            LevelView()
                .tabItem { Label("Levels", systemImage: "speaker.wave.3") }
            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
