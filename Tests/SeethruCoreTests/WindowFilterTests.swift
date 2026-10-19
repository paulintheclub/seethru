import CoreGraphics
import Testing
@testable import SeethruCore

private func raw(_ n: UInt32, pid: Int32 = 100, owner: String = "App", layer: Int = 0,
                 w: CGFloat = 800, h: CGFloat = 600, onScreen: Bool = true) -> RawWindow {
    RawWindow(number: n, pid: pid, ownerName: owner, layer: layer, bounds: CGRect(x: 0, y: 0, width: w, height: h), isOnScreen: onScreen)
}

private func info(_ n: UInt32, pid: Int32, owner: String) -> WindowInfo {
    WindowInfo(id: WindowID(pid: pid, number: n), ownerName: owner, bundleID: "id.\(owner)")
}

@Suite struct WindowFilterTests {
    @Test func keepsNormalWindows() {
        #expect(WindowFilter.filter([raw(1)], ownPID: 1).map(\.number) == [1])
    }

    @Test func dropsNonZeroLayers() {
        #expect(WindowFilter.filter([raw(1, layer: 25), raw(2, layer: -1), raw(3)], ownPID: 1).map(\.number) == [3])
    }

    @Test func dropsOffScreenAndTinyWindows() {
        let out = WindowFilter.filter([raw(1, onScreen: false), raw(2, w: 20, h: 20), raw(3, w: 500, h: 79), raw(4)], ownPID: 1)
        #expect(out.map(\.number) == [4])
    }

    @Test func dropsOwnWindowsAndSystemOwners() {
        let out = WindowFilter.filter([raw(1, pid: 7), raw(2, owner: "Dock"), raw(3, owner: "Window Server"), raw(4, pid: 8)], ownPID: 7)
        #expect(out.map(\.number) == [4])
    }

    @Test func parsesCGWindowDictionary() {
        let dict: [String: Any] = [
            kCGWindowNumber as String: 42, kCGWindowOwnerPID as String: 99, kCGWindowLayer as String: 0,
            kCGWindowOwnerName as String: "Safari", kCGWindowName as String: "Home", kCGWindowAlpha as String: 0.5,
            kCGWindowIsOnscreen as String: true,
            kCGWindowBounds as String: ["X": 10, "Y": 20, "Width": 300, "Height": 200],
        ]
        let w = WindowFilter.parse(dict)
        #expect(w?.number == 42)
        #expect(w?.pid == 99)
        #expect(w?.title == "Home")
        #expect(w?.alpha == 0.5)
        #expect(w?.bounds == CGRect(x: 10, y: 20, width: 300, height: 200))
        #expect(w?.isOnScreen == true)
    }

    @Test func parseRejectsIncompleteRows() {
        #expect(WindowFilter.parse([kCGWindowNumber as String: 1]) == nil)
    }

    @Test func groupsByAppSortedByNameKeepingZOrder() {
        let ws = [info(1, pid: 20, owner: "Zed"), info(2, pid: 10, owner: "alpha"), info(3, pid: 20, owner: "Zed"), info(4, pid: 30, owner: "Mail")]
        let groups = WindowFilter.group(ws)
        #expect(groups.map(\.name) == ["alpha", "Mail", "Zed"])
        #expect(groups[2].windows.map(\.id.number) == [1, 3])
    }

    @Test func frontmostWindowIsFirstOfThatPid() {
        let ws = [info(1, pid: 20, owner: "Zed"), info(2, pid: 10, owner: "alpha"), info(3, pid: 10, owner: "alpha")]
        #expect(WindowFilter.frontmostWindow(of: 10, in: ws)?.id.number == 2)
        #expect(WindowFilter.frontmostWindow(of: 99, in: ws) == nil)
    }
}
