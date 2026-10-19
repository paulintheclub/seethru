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

| | Mirror (default) | SkyLight |
|---|---|---|
| How | ScreenCaptureKit stream of the window drawn into a borderless overlay with `alphaValue < 1`; the original is moved off-screen with Accessibility | `SLSSetWindowAlpha` |
| SIP on | works (capture + overlay verified) | rc 0 but ignored for foreign windows, so it fails by read-back |
| Permissions | Screen Recording, Accessibility | none |
| Always on top / click-through | overlay level / `ignoresMouseEvents` | not supported |

Mirror details (`Mirror/MirrorSession.swift`): the overlay is an `NSPanel` (non-activating, never key). Clicking it activates the
owning app and raises the hidden window, so keyboard input reaches the app naturally; mouse and scroll events are translated into
the hidden window's coordinates and posted with `CGEvent.postToPid`. A 10 Hz tick follows moves/resizes of the hidden window
and keeps the overlay directly above it in z-order.

## Safety

- `shutdown()` runs on quit, SIGTERM, SIGINT, SIGHUP and restores every window.
- Before the mirror backend parks a window, its home position goes into `hidden-windows.json`. If Seethru dies
  (crash, SIGKILL) the next launch moves those windows back (`MirrorBackend.recoverHiddenWindows`).
- After sleep/wake every managed window is restored and re-applied.
- Backends verify instead of trusting return codes; failures show as a message in the menu.

## Persistence

`~/Library/Application Support/Seethru/rules.json` (versioned, atomic writes, migrated by `RulesMigrator`; an unreadable or
newer file is moved to `rules.json.bak`, never overwritten) and `hidden-windows.json`. The backend choice is in `UserDefaults`.
