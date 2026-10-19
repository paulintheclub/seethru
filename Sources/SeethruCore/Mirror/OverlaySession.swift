import Foundation

/// One transparent window. Two implementations:
/// - `InPlaceSession`: the original stays where it is and keeps receiving real input.
/// - `MirrorSession` ("parked"): the original is moved off-screen; needed for click-through / always-on-top.
@MainActor
protocol OverlaySession: AnyObject {
    var isParked: Bool { get }
    var onEnded: (@MainActor (WindowID, BackendError?) -> Void)? { get set }
    func start() async throws
    func update(alpha: Double, options: WindowOptions)
    /// Called when other Seethru windows appear or disappear so backdrop captures keep excluding them.
    func refreshFilters() async
    func stop()
}
