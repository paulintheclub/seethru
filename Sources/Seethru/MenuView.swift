import AppKit
import SeethruCore
import SwiftUI

let brand = Color(red: 0.12, green: 0.75, blue: 0.62)

struct MenuView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var expanded: Set<Int32> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.missingPermissions.isEmpty {
                if let error = model.lastError { errorBanner(error) }
                Divider()
                list
            } else {
                Divider()
                permissionGate
            }
            Divider()
            footer
        }
        .frame(width: 340)
        .tint(brand)
    }

    // MARK: sections

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 26, height: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text("Seethru").font(.headline)
                Text(model.activeCount == 0 ? "Nothing transparent" : "\(model.activeCount) window\(model.activeCount == 1 ? "" : "s") transparent")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    /// Seethru does nothing until both permissions are granted, so nothing can half-work later.
    private var permissionGate: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.shield").font(.largeTitle).foregroundStyle(.orange)
            Text("Seethru needs two permissions")
                .font(.headline)
            Text("Missing: \(model.missingPermissions.map(\.rawValue).joined(separator: " and "))")
                .font(.callout).foregroundStyle(.secondary)
            Button("Set up…") { bringToFront(openWindow, WindowID.onboarding) }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 28)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { model.clearError() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("Dismiss message")
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    private var list: some View {
        Group {
            if model.groups.isEmpty {
                Text("No windows found.\nOpen an app window and it will show up here.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity).padding(.vertical, 28)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.groups) { group in
                            AppRow(model: model, group: group, expanded: binding(for: group))
                        }
                    }
                    .padding(8)
                }
                .frame(height: min(CGFloat(rowCount) * 54 + 16, 400))
            }
        }
    }

    private var rowCount: Int {
        model.groups.reduce(0) { $0 + 1 + (expanded.contains($1.id) && $1.windows.count > 1 ? $1.windows.count : 0) }
    }

    private func binding(for group: AppGroup) -> Binding<Bool> {
        Binding(get: { expanded.contains(group.id) },
                set: { if $0 { expanded.insert(group.id) } else { expanded.remove(group.id) } })
    }

    private var footer: some View {
        HStack {
            Button("Reset all") { model.resetAll() }
                .disabled(model.activeCount == 0)
                .keyboardShortcut("r")
            Spacer()
            Button("Settings…") { bringToFront(openWindow, WindowID.settings) }
                .keyboardShortcut(",")
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(10)
    }
}

struct AppRow: View {
    let model: AppModel
    let group: AppGroup
    @Binding var expanded: Bool

    private var isSingle: Bool { group.windows.count == 1 }
    private var value: Double { group.windows.map { model.opacity(of: $0.id) }.min() ?? 1 }
    private var rule: AppRule? { model.rule(for: group) }
    private var options: WindowOptions { group.windows.first.map { model.windowOptions(of: $0.id) } ?? .none }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                if !isSingle {
                    Button { withAnimation(.snappy(duration: 0.15)) { expanded.toggle() } } label: {
                        Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 12)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expanded ? "Hide windows of \(group.name)" : "Show windows of \(group.name)")
                } else {
                    Color.clear.frame(width: 12)
                }
                icon
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Text(group.name).lineLimit(1)
                        if rule != nil { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(brand).help("Remembered for this app") }
                    }
                    if isSingle {
                        Text(group.windows[0].displayTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Text("\(group.windows.count) windows").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                OpacitySlider(value: value, label: group.name) { model.setOpacity(app: group, $0) }
                    .frame(width: 96)
                menu
            }
            .padding(.vertical, 5).padding(.horizontal, 6)

            if expanded && !isSingle {
                ForEach(group.windows) { w in
                    HStack(spacing: 8) {
                        Text(w.displayTitle).font(.callout).lineLimit(1).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        OpacitySlider(value: model.opacity(of: w.id), label: w.displayTitle) { model.setOpacity(w, $0) }
                            .frame(width: 96)
                        Color.clear.frame(width: 22)
                    }
                    .padding(.leading, 40).padding(.trailing, 6).padding(.vertical, 2)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(value < 1 ? 0.06 : 0)))
    }

    @ViewBuilder private var icon: some View {
        if let img = NSRunningApplication(processIdentifier: group.id)?.icon {
            Image(nsImage: img).resizable().frame(width: 24, height: 24).accessibilityHidden(true)
        } else {
            Image(systemName: "macwindow").frame(width: 24, height: 24).accessibilityHidden(true)
        }
    }

    private var menu: some View {
        Menu {
            if group.bundleID != nil {
                Toggle("Remember for this app", isOn: Binding(
                    get: { rule != nil },
                    set: { on in on ? model.remember(app: group) : model.forgetRule(bundleID: group.bundleID!) }))
            }
            if model.capabilities.contains(.alwaysOnTop) {
                Toggle("Always on top", isOn: Binding(
                    get: { options.alwaysOnTop },
                    set: { model.setOptions(app: group, WindowOptions(alwaysOnTop: $0, clickThrough: options.clickThrough)) }))
            }
            if model.capabilities.contains(.clickThrough) {
                Toggle("Click-through", isOn: Binding(
                    get: { options.clickThrough },
                    set: { model.setOptions(app: group, WindowOptions(alwaysOnTop: options.alwaysOnTop, clickThrough: $0)) }))
            }
            Divider()
            Button("Reset this app") { model.reset(app: group) }
            if group.bundleID != nil { Button("Never touch this app") { model.exclude(app: group) } }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .frame(width: 22)
        .accessibilityLabel("More options for \(group.name)")
    }
}

struct OpacitySlider: View {
    let value: Double
    let label: String
    let onChange: (Double) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Slider(value: Binding(get: { value }, set: { onChange($0) }), in: 0.1...1)
                .controlSize(.small)
                .accessibilityLabel("Opacity of \(label)")
                .accessibilityValue("\(Int((value * 100).rounded())) percent")
            Text("\(Int((value * 100).rounded()))")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
        }
    }
}
