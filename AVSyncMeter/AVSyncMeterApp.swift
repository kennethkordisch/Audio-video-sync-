import SwiftUI

@main
struct AVSyncMeterApp: App {
    init() {
        AppSettings.registerDefaults()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
