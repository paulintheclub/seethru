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

| | Mirror, in-place (default) | Mirror, parked (click-through / always-on-top) | SkyLight |
|---|---|---|---|
| How | original stays put; above it two click-through panels: a backdrop (display capture without the window) and a live copy at alpha < 1 | copy in an overlay, original moved off-screen with Accessibility, strip macOS leaves visible covered by a backdrop panel | `SLSSetWindowAlpha` |
| Result | alpha x window + (1 - alpha) x backdrop | same look | rc 0 but ignored for foreign windows (SIP on) |
| Input | real: clicks, scroll and typing reach the real window | forwarded with `CGEvent.postToPid` (unreliable, e.g. Chrome ignores it) | n/a |
| Permissions | Screen Recording | Screen Recording + Accessibility | none |
| If Seethru dies | nothing to restore | `hidden-windows.json` journal moves windows back on next launch | n/a |

In-place details (`Mirror/InPlaceSession.swift`, `Mirror/StripCover.swift` = `BackdropCover`): a 30 Hz tick follows the original's
frame from `CGWindowList` (no Accessibility), and a global mouse monitor re-stacks the panels right after a click raises the
original (stack, front to back: overlay, backdrop, original). The panels are flagged non-opaque on purpose so the window server
still counts the original as visible and apps like Chrome keep rendering. The backdrop capture excludes the original and all
Seethru windows (`refreshFilters` runs when the set of sessions changes). Known limit: two overlapping transparent windows show
the other one opaque in the backdrop.

## Safety

- `shutdown()` runs on quit, SIGTERM, SIGINT, SIGHUP and restores every window.
- In-place mode never moves anything. Before parked mode moves a window, its home position goes into `hidden-windows.json`. If Seethru dies
  (crash, SIGKILL) the next launch moves those windows back (`MirrorBackend.recoverHiddenWindows`).
- After sleep/wake every managed window is restored and re-applied.
- Backends verify instead of trusting return codes; failures show as a message in the menu.

## Persistence

`~/Library/Application Support/Seethru/rules.json` (versioned, atomic writes, migrated by `RulesMigrator`; an unreadable or
newer file is moved to `rules.json.bak`, never overwritten) and `hidden-windows.json`. The backend choice is in `UserDefaults`.
