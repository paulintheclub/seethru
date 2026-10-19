import Foundation

public enum OpacityStepper {
    public static let minimum = 0.1
    public static let maximum = 1.0

    public enum Direction: Sendable { case moreOpaque, moreTransparent }

    public static func clamp(_ v: Double) -> Double { min(maximum, max(minimum, v)) }

    /// One hotkey step. Result is rounded to 0.01 so repeated presses never drift (0.1 + 0.1 + 0.1 != 0.3 in floats).
    public static func step(_ current: Double, _ direction: Direction, by amount: Double = 0.1) -> Double {
        let delta = direction == .moreOpaque ? amount : -amount
        return clamp(((current + delta) * 100).rounded() / 100)
    }
}
