import Foundation

public struct PlannedAction: Equatable, Sendable {
    public var window: WindowInfo
    public var opacity: Double
    public var options: WindowOptions
}

public enum RuleApplier {
    /// Which rules to apply now. Only windows not yet `handled` get a rule applied, so a window the user
    /// resets by hand is not re-dimmed on the next refresh. Excluded apps are never touched.
    public static func plan(windows: [WindowInfo], rules: RulesFile, handled: Set<WindowID>) -> [PlannedAction] {
        windows.compactMap { w in
            guard !handled.contains(w.id),
                  !rules.isExcluded(w.bundleID),
                  let rule = rules.rule(for: w.bundleID),
                  rule.opacity < 0.999 || rule.alwaysOnTop || rule.clickThrough
            else { return nil }
            return PlannedAction(window: w, opacity: OpacityStepper.clamp(rule.opacity), options: rule.options)
        }
    }
}
