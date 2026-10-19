import AppKit
import SeethruCore
import SwiftUI

struct OnboardingView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Let Seethru see your windows").font(.title2.bold())
                    Text("Everything stays on this Mac. Nothing is sent anywhere.").foregroundStyle(.secondary)
                }
            }
            PermissionRow(
                title: "Screen Recording",
                reason: "Seethru draws a live, see-through copy of the window you choose. macOS calls that screen recording. Nothing is stored or sent.",
                granted: model.permissions.screenRecording
            ) { Permissions.request(.screenRecording) }
            PermissionRow(
                title: "Accessibility",
                reason: "Lets Seethru move a window out of sight and back, which click-through and always-on-top need. Nothing is read or recorded with it.",
                granted: model.permissions.accessibility
            ) { Permissions.request(.accessibility) }

            Text("Seethru needs both to work. After you switch one on, macOS may ask you to quit and reopen Seethru; if a row stays unchecked, use Relaunch.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Quit Seethru") { NSApp.terminate(nil) }
                Button("Relaunch Seethru") { relaunch() }
                Spacer()
                Button("Continue") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.permissions.allGranted)
            }
        }
        .padding(24)
        .frame(width: 520)
        .tint(brand)
    }

    private func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", path]
        try? p.run()
        model.shutdown()
        NSApp.terminate(nil)
    }
}

private struct PermissionRow: View {
    let title: String
    let reason: String
    let granted: Bool
    let grant: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title2).foregroundStyle(granted ? brand : .secondary)
                .accessibilityLabel(granted ? "Granted" : "Not granted")
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !granted {
                Button("Grant…", action: grant)
                    .accessibilityLabel("Grant \(title) permission")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}
