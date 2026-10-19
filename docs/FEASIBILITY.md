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

Results: _pending_.

## Decision gate

- A fails (above). Mirror backend (B) is the candidate primary backend, pending the user's run of the spike.
- If B is unacceptable, stop and keep this document as the write-up.
