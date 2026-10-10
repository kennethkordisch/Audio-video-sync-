import SwiftUI

@main
struct AVSyncPatternMakerApp: App {
    var body: some Scene {
        WindowGroup("AV Sync Pattern Maker") {
            ContentView()
                .frame(minWidth: 560, minHeight: 720)
        }
        .windowResizability(.contentSize)
    }
}
