import AppKit
import SeethruCore
import SwiftUI

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            GeneralTab(model: model).tabItem { Label("General", systemImage: "gearshape") }
            RulesTab(model: model).tabItem { Label("Apps", systemImage: "pin") }
            HotkeysTab(model: model).tabItem { Label("Hotkeys", systemImage: "keyboard") }
            AboutTab().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 400)
        .tint(brand)
    }
}

private struct GeneralTab: View {
    let model: AppModel
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginError: String?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Open Seethru at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { try LaunchAtLogin.setEnabled(on); loginError = nil } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                if LaunchAtLogin.needsApproval {
                    Text("Approve Seethru under System Settings → General → Login Items.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("How windows are made transparent") {
                Picker("Method", selection: $model.backendKind) {
                    ForEach(BackendKind.allCases) { Text($0.title).tag($0) }
                }
                Text(model.backendKind == .mirror
                     ? "Shows a live see-through copy of the window and parks the original off-screen. Works with System Integrity Protection on. Needs Screen Recording and Accessibility."
                     : "Asks the window server to change the window's alpha directly. macOS ignores this for other apps' windows when SIP is on, so Seethru will report a failure. Kept for testing.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Permissions") {
                LabeledContent("Screen Recording") { Text(model.permissions.screenRecording ? "Granted" : "Not granted") }
                LabeledContent("Accessibility") { Text(model.permissions.accessibility ? "Granted" : "Not granted") }
                Button("Open permission setup…") { bringToFront(openWindow, WindowID.onboarding) }
            }
            if model.recoveredWindows > 0 {
                Section { Text("Recovered \(model.recoveredWindows) window(s) left off-screen by a previous run.").font(.caption) }
            }
        }
        .formStyle(.grouped)
    }
}

private struct RulesTab: View {
    let model: AppModel

    var body: some View {
        List {
            Section("Remembered apps") {
                if model.rules.rules.isEmpty {
                    Text("Use “Remember for this app” in the menu bar window. New windows of that app then open already transparent.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(model.rules.rules) { r in
                    HStack {
                        Text(r.appName)
                        Spacer()
                        Text("\(Int((r.opacity * 100).rounded()))%").foregroundStyle(.secondary).monospacedDigit()
                        if r.alwaysOnTop { Image(systemName: "pin").help("Always on top") }
                        if r.clickThrough { Image(systemName: "cursorarrow.slash").help("Click-through") }
                        Button { model.forgetRule(bundleID: r.bundleID) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).accessibilityLabel("Forget rule for \(r.appName)")
                    }
                }
            }
            Section("Never touched") {
                if model.rules.excluded.isEmpty {
                    Text("Apps you exclude from the menu appear here.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(model.rules.excluded) { e in
                    HStack {
                        Text(e.appName)
                        Spacer()
                        Button("Allow again") { model.include(bundleID: e.bundleID) }.buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}

private struct HotkeysTab: View {
    let model: AppModel

    var body: some View {
        Form {
            Section("Global hotkeys (work in any app, no extra permission)") {
                ForEach(HotKeyBinding.defaults, id: \.action) { b in
                    LabeledContent(b.action.title) {
                        HStack {
                            Text(b.display).monospacedDigit()
                            if model.failedHotKeys.contains(b.action) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                                    .help("Another app already uses this combination")
                            }
                        }
                    }
                }
            }
            Text("Custom shortcuts are planned. The frontmost window is the top-most window of the app you are using.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct AboutTab: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "dev") (\(info?["CFBundleVersion"] as? String ?? "0"))"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
            Text("Seethru").font(.title.bold())
            Text("Version \(version)").foregroundStyle(.secondary)
            Text("Change how see-through any app's windows are. Runs entirely on this Mac: no network, no telemetry, no accounts.")
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            Text("Uses private macOS interfaces, so it can stop working after a macOS update.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
            Text("MIT License").font(.caption).foregroundStyle(.secondary)
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
