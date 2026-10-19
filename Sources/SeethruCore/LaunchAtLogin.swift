import ServiceManagement

public enum LaunchAtLogin {
    public static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    public static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    public static func setEnabled(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
