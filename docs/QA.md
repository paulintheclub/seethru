# Manual QA checklist

Run with a fresh build (`scripts/run.sh`). Tick per macOS version / chip and note failures in an issue.

Setup: grant Screen Recording and Accessibility, relaunch Seethru. Note the macOS version and chip.

For each app below: set 50% from the menu, then check **(a)** it looks see-through and the original is not visible
underneath, **(b)** scrolling, clicking, hover and typing still work, **(c)** moving and resizing the window, **(d)** "Reset"
returns it exactly where it was, **(e)** quitting Seethru while it is transparent restores it.

- [ ] Safari
- [ ] Google Chrome
- [ ] Terminal
- [ ] Finder
- [ ] VS Code (Electron)
- [ ] A Catalyst app (e.g. Messages, Maps)
- [ ] An app with several windows (per-window slider vs per-app slider)
- [ ] A full-screen app (expected: unsupported, must fail gracefully)
- [ ] Two displays: drag the transparent window to the other display; mixed Retina/non-Retina
- [ ] Spaces: switch Spaces while a window is transparent; assign window to all Spaces
- [ ] Stage Manager on
- [ ] Liquid Glass windows on macOS 26
- [ ] Sleep and wake with a transparent window
- [ ] `kill -9` Seethru while a window is transparent, relaunch: the window comes back on screen
- [ ] Hotkeys: more/less transparent, reset, peek; a clash with another app's shortcut shows a warning in Settings
- [ ] Rules: "Remember for this app", open a new window of that app, it is already transparent; "Never touch this app"
- [ ] Launch at login
- [ ] VoiceOver: every control reachable with the keyboard and has a label
- [ ] Permission onboarding: status flips after granting; deep links open the right pane
- [ ] Crowded menu bar (icon hidden): reopening the app from Finder opens the Seethru window
