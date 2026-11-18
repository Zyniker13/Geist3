import SwiftUI

/// Parlor app entry point, shared by the iOS and macOS targets (P0.2).
@main
struct ParlorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// Placeholder root view. Replaced by the real table UI in P5.
struct ContentView: View {
    var body: some View {
        Text("Parlor")
            .font(.largeTitle)
            .padding()
    }
}

/// Build metadata exposed to unit tests.
public enum ParlorBuildInfo {
    public static let name = "Parlor"
}
