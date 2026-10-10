import SwiftUI

@main
struct AVSyncPatternMakerApp: App {
    init() {
        // `--render ...` renders headlessly and exits before any window appears.
        CommandLineRunner.runIfRequested()
    }

    var body: some Scene {
        WindowGroup("AV Sync Pattern Maker") {
            ContentView()
                .frame(minWidth: 560, minHeight: 720)
        }
        .windowResizability(.contentSize)
    }
}
