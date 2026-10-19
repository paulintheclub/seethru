import AppKit
import SeethruCore
import SwiftUI

@main
struct SeethruApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: delegate.model)
        } label: {
            MenuBarLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.window)

        Window("Seethru Settings", id: WindowID.settings) {
            SettingsView(model: delegate.model)
        }
        .windowResizability(.contentSize)

        Window("Welcome to Seethru", id: WindowID.onboarding) {
            OnboardingView(model: delegate.model)
        }
        .windowResizability(.contentSize)
    }
}

enum WindowID {
    static let settings = "settings"
    static let onboarding = "onboarding"
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        // Never leave a window transparent or parked off-screen when we are asked to stop.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [model] in
                MainActor.assumeIsolated { model.shutdown() }
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}

/// Brings one of our windows to the front. A menu bar (LSUIElement) app is never active on its own.
@MainActor
func bringToFront(_ openWindow: OpenWindowAction, _ id: String) {
    openWindow(id: id)
    NSApp.activate()
}
