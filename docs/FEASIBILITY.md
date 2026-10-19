# Feasibility findings

Environment: macOS 26.6.2 (25G83), Apple Silicon, SIP enabled, Swift 6.3.3, Command Line Tools only (no Xcode).

## Spike A — SkyLight alpha on a foreign window (SIP on)

Sources: `spikes/spike_a_skylight.swift`, `spikes/target_window.swift`, `spikes/control_own_window.swift`.

Symbols resolved with `dlopen(SkyLight)` + `dlsym`: all present
(`SLSMainConnectionID`, `SLSSetWindowAlpha`, `CGSSetWindowAlpha`, `SLSSetWindowListAlpha`, `SLSGetWindowAlpha`,
`SLSSetWindowLevel`, `SLSSetWindowTags`, `SLSClearWindowTags`, `SLSSetWindowShape`, `SLSOrderWindow`, `SLSSetWindowOpacity`, ...).

| Case | Call | Return code | Window server read-back |
|---|---|---|---|
| Control: window owned by the calling process | `SLSSetWindowAlpha(cid, wid, 0.4)` | 0 | `kCGWindowAlpha` = 0.4 (**works**) |
| Foreign window (separate throwaway process) | `SLSSetWindowAlpha(cid, wid, 0.5)` | 0 | `kCGWindowAlpha` = 1.0, `SLSGetWindowAlpha` = 1.0 (**ignored**) |
| Foreign window | `CGSSetWindowAlpha` | (not reached, SLS variant returned 0) | - |
| Foreign window | `SLSSetWindowListAlpha` | 0 | 1.0 (**ignored**) |

Conclusion: the calls succeed (rc = 0) but the window server silently ignores them for windows owned by another
connection. A zero return code is not evidence that anything changed; always read back `kCGWindowAlpha`.
Because nothing changes, there is no "alpha survives a crash" problem for this path.

The read-back is a strong programmatic signal, but the visual check on a real app (Safari, Chrome) is still worth
doing: `.build/SpikeA "Google Chrome" 0.5 5` and watch the window.

**Verdict: Spike A fails with SIP on. SkyLight cannot be the primary backend.**
The `SkyLightBackend` in the app is kept as an opt-in probe that verifies via read-back and reports failure honestly.

## Spike B — Mirror overlay (SIP on)

Source: `spikes/spike_b_mirror.swift`. It needs Screen Recording and Accessibility, which only the user can grant
to Terminal, so it has **not been run yet**. Run it from Terminal:

```
swiftc -O -swift-version 5 spikes/spike_b_mirror.swift -o .build/SpikeB
.build/SpikeB "Safari" --alpha 0.5                    # capture + overlay on top of the original
.build/SpikeB "Safari" --alpha 0.5 --hide             # also move the original off-screen via Accessibility
.build/SpikeB "Safari" --alpha 0.5 --hide --forward   # also forward mouse/keyboard to the hidden original
```

Things to report (the spike prints `RESULT` lines for the first three):

1. Does ScreenCaptureKit deliver frames (fps)?
2. With `--hide`: does macOS clamp the off-screen position back? Do frames keep coming while the window is off-screen?
3. With `--forward`: how many events were forwarded; do clicks, scrolling, typing reach the hidden window?
4. Visually: latency, hover effects, drag, text input, shadows, secure content.

### Results so far (overlay-only run, `.build/SpikeB SpikeTarget --alpha 0.5`)

Run from the agent's shell, which had Screen Recording but **not** Accessibility, so only step 1 and the overlay itself could be tested.

| Check | Result |
|---|---|
| ScreenCaptureKit frames for a foreign window | **Works.** First frame immediately, ~61 fps, 840x584 px IOSurface for a 420x292 pt window. |
| Zero-copy display (`layer.contents = IOSurface`) | **Works.** |
| Overlay at `alphaValue = 0.5` above the original | **Works** (confirmed in a screenshot: the overlay is see-through). The original was still under it, so this alone shows a double image. |
| Move the original off-screen via Accessibility (`--hide`) | **Not tested yet.** Needs Accessibility for the terminal. |
| Do frames keep coming while the original is off-screen | **Not tested yet.** |
| Input forwarding (`--forward`) | **Not tested yet.** |

The app's `MirrorBackend` implements the full design (hide via AX with off-screen candidates, read-back check that
refuses to continue if macOS clamps the window, crash journal, mouse forwarding). It fails with a clear message
instead of showing a double image if the original cannot be hidden.

## Decision gate

- A fails (above). Mirror backend (B) is the primary backend in the app; capture and overlay are proven, hiding the original is still to be confirmed on the user's Mac.
- If B is unacceptable, stop and keep this document as the write-up.
