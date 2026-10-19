# Contributing

- Build: `scripts/build.sh` (app bundle in `build/`), run: `scripts/run.sh`, tests: `scripts/test.sh`.
- Works with the Xcode Command Line Tools alone; Xcode is not required.
- Private API use stays inside `Sources/PrivateAPI/` behind protocols and is resolved with `dlsym`.
- Visual features are not done until someone has looked at them on a real screen. Say which macOS version and chip.
- Keep changes small; add unit tests for pure logic (filtering, rules, stepping).
- No network access, no telemetry, no accounts. Pull requests adding any are declined.
- Do not use third-party trademarks in the name, bundle id or branding.

macOS permissions follow the app's code signature. Sign development builds with a stable identity
(`SIGN_IDENTITY="Apple Development: ..." scripts/build.sh`) or macOS asks again after every rebuild.
