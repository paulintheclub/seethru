# Architecture

```
Sources/
  PrivateAPI/    every private symbol, resolved with dlsym, behind protocols
  SeethruCore/   engine: window listing, backends, rules, hotkeys, AppModel (no SwiftUI)
  Seethru/       menu bar app: MenuBarExtra, settings, onboarding
Tests/SeethruCoreTests/
tools/           test_window.swift: a throwaway window for stress-testing
```

## Flow

`AppModel` (main actor, `@Observable`) ticks once a second and on app launch/quit/activate notifications:

1. `CGWindowService.snapshot()` lists windows; `WindowFilter` keeps layer-0, on-screen, non-tiny, non-own windows.
2. Managed windows that vanished from the on-screen list are checked with `windowExists` (a mirrored original is parked
   off-screen and may drop out of the list) and kept in the UI from a cache.
3. `RuleApplier.plan` decides which per-app rules apply to windows not handled yet. A window the user resets by hand
   is marked handled and not re-dimmed.
4. Changes go to the `OpacityBackend`.

## Backends (`OpacityBackend`)

| | In-place (default) | Parked (click-through / always-on-top) |
|---|---|---|
| How | original stays put; above it two click-through panels: a backdrop (display capture without the window) and a live copy at alpha < 1 | copy in an overlay, original moved off-screen with Accessibility, the strip macOS leaves visible covered by a backdrop panel |
| Result | alpha x window + (1 - alpha) x backdrop | same look |
| Input | real: clicks, scroll and typing reach the real window | forwarded with `CGEvent.postToPid` (unreliable: Chrome ignores it), so only useful with click-through |
| Permissions | both are required at first launch; the app is gated until granted | same |
| If Seethru dies | nothing to restore | `hidden-windows.json` journal moves windows back on next launch |


In-place details (`Mirror/InPlaceSession.swift`, `Mirror/BackdropCover.swift`, `Mirror/BackdropHub.swift`):

- **Stacking.** Both panels use the floating window level, so they stay above the original whatever the app does with its own
  stacking (a click raises the window; at normal level that made the transparency vanish for a moment). Windows that really are
  above the original (another app's window, a popup) are cut out of the panels with a rounded-rect mask (`HoleMask`), computed
  from one window-list snapshot per tick. Tiny windows of the app itself (e.g. the traffic lights) are not cut out.
- **One timer for everything.** `StackCoordinator` runs one 60 Hz timer and takes one `CGWindowList` snapshot per tick for all
  sessions; it also reacts immediately to mouse clicks. (An earlier version had one timer and two list queries per session and
  re-ordered the panels 60 times a second per window, which was the main cost: WindowServer +25-30 points of one core with three
  windows, +9 now.)
- **Shared backdrop.** One display capture per display serves all backdrop panels on it: it covers the union of their
  rectangles, excludes all Seethru windows and all managed originals, and each panel shows its own crop via `contentsRect`.
  Known limit: two overlapping transparent windows see through each other's original.
- **Recovery.** If a capture stops on its own (display change, sleep) it is restarted; a session gives up only after repeated
  failures within a minute. A hidden or minimized window is looked up in the full window list (it is missing from the on-screen
  list but still exists); its captures are stopped until it is back.
- The panels never hide when Seethru is not the active app (`hidesOnDeactivate = false`, `canHide = false`).

## Safety

- `shutdown()` runs on quit, SIGTERM, SIGINT, SIGHUP and restores every window.
- In-place mode never moves anything. Before parked mode moves a window, its home position goes into `hidden-windows.json`. If Seethru dies
  (crash, SIGKILL) the next launch moves those windows back (`MirrorBackend.recoverHiddenWindows`).
- After sleep/wake every managed window is restored and re-applied.
- Backends verify instead of trusting return codes; failures show as a message in the menu.

## Persistence

`~/Library/Application Support/Seethru/rules.json` (versioned, atomic writes, migrated by `RulesMigrator`; an unreadable or
newer file is moved to `rules.json.bak`, never overwritten) and `hidden-windows.json`. The backend choice is in `UserDefaults`.
