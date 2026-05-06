import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct YearlyInterviewStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("Yearly Interview Studio") {
            ContentView()
                .environmentObject(appState)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1440, height: 920)
        .commands {
            StudioWindowCommands()
        }

        Window("Sequence", id: StudioWindowID.sequence) {
            SequenceWindowView()
                .environmentObject(appState)
        }
        .defaultSize(width: 760, height: 900)

        Window("Issues", id: StudioWindowID.issues) {
            IssuesWindowView()
                .environmentObject(appState)
        }
        .defaultSize(width: 760, height: 900)
    }
}
