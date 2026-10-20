# Architecture

```
Sources/
  PrivateAPI/    every private symbol, resolved with dlsym, behind protocols
  SeethruCore/   engine: window listing, backends, rules, hotkeys, AppModel (no SwiftUI)
  Seethru/       menu bar app: MenuBarExtra, settings, onboarding
Tests/SeethruCoreTests/
spikes/          standalone feasibility programs (see FEASIBILITY.md)
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

A direct SkyLight alpha backend was tried and removed: macOS ignores it for other apps' windows with SIP on (docs/FEASIBILITY.md).

In-place details (`Mirror/InPlaceSession.swift`, `Mirror/StripCover.swift` = `BackdropCover`): a 60 Hz tick follows the original's
frame from `CGWindowList` (no Accessibility) and checks the stacking with a cheap `optionOnScreenAboveWindow` query; a global mouse
monitor and app-activation notifications trigger bursts of re-stacking right after a click raises the original (stack, front to back: overlay, backdrop, original). The panels are flagged non-opaque on purpose so the window server
still counts the original as visible and apps like Chrome keep rendering. One display capture per display is shared by all backdrop panels on it (`Mirror/BackdropHub.swift`): it covers the union of their
rectangles, excludes all Seethru windows and all managed originals, and each panel shows its own crop via `contentsRect`. With
three windows this costs about the same as with one (WindowServer ~77% vs 89-101% with one capture per window). While a window is
not on screen (minimized, other Space, hidden app) its captures are stopped. Known limit: two overlapping transparent windows
see through each other's original instead of each other's blended look.

## Safety

- `shutdown()` runs on quit, SIGTERM, SIGINT, SIGHUP and restores every window.
- In-place mode never moves anything. Before parked mode moves a window, its home position goes into `hidden-windows.json`. If Seethru dies
  (crash, SIGKILL) the next launch moves those windows back (`MirrorBackend.recoverHiddenWindows`).
- After sleep/wake every managed window is restored and re-applied.
- Backends verify instead of trusting return codes; failures show as a message in the menu.

## Persistence

`~/Library/Application Support/Seethru/rules.json` (versioned, atomic writes, migrated by `RulesMigrator`; an unreadable or
newer file is moved to `rules.json.bak`, never overwritten) and `hidden-windows.json`. The backend choice is in `UserDefaults`.
