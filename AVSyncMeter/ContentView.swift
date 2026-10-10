import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            MeasureView()
                .tabItem { Label("Measure", systemImage: "timer") }
            TestPatternView()
                .tabItem { Label("Test Pattern", systemImage: "play.rectangle") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
