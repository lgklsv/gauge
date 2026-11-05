# Gauge

A small native macOS menu bar app for Codex usage. Swift and AppKit, no dependencies, no Dock icon, no separate settings window.

- Subscription usage, reset countdowns, and progress bars for the 5-hour and weekly windows.
- OpenAI mark with a usage ring in the menu bar.
- Estimated API cost and token totals for today, the last 7 days, and the last 30 days, plus a 7-day sparkline.
- Code-review usage and credit balance when returned by Codex.
- Refresh, open Codex Usage, launch at login, and quit.

## Build and run

Requires macOS 13 or newer and Xcode with its command-line tools selected.

```sh
./scripts/build.sh
```

Open `build/Gauge.app`, or copy it to `/Applications` first. Launch at login is registered on the first app launch; change it in the menu or macOS Login Items settings. Keep the app at a stable location for login launching.

The build uses local ad-hoc signing automatically. No Apple Developer account, signing certificate, or notarization is needed for this locally built app. Downloaded builds on other Macs may be subject to Gatekeeper checks.

Open `Package.swift` in Xcode to edit the source. Run the build script to produce the app bundle, resources, icon, and local signature. Builds target the current Mac's architecture.

## Data and resource use

Gauge reads the existing Codex login from `$CODEX_HOME/auth.json` (default `~/.codex/auth.json`) and calls `https://chatgpt.com/backend-api/wham/usage` with `URLSession`. This is an internal endpoint and may change. There is no persistent Codex subprocess. Credentials are never copied into Gauge's cache or logged. Gauge does not refresh OAuth tokens: if the session expires, sign in through Codex again. Keychain-only Codex credential storage is not currently supported.

Subscription usage refreshes roughly once a minute, when opening an outdated menu, and after waking. Requests never overlap. Failed requests use exponential backoff (up to 30 minutes) and respect longer server Retry-After values, including for manual refresh. Saved usage remains visible after an error. Countdown labels update only while the menu is open. No animations or continuous rendering.

API estimates are computed locally from `~/.codex/sessions/**/*.jsonl`. This is the estimated API equivalent, **not a bill or subscription charge**. Prices use the same LiteLLM table as the original SwiftBar plugin, cached for 24 hours. Only the model pricing table is downloaded; session contents are not uploaded.

The first pass indexes recent logs. Subsequent passes inspect file metadata and read only appended records. Incomplete final lines wait for the next pass. Token events are retained for 32 days, even if the source log disappears. Fork-copy suppression and consecutive duplicate token-event suppression follow the original plugin. Costs use uncached input, cached input, cache-write, and output token rates; reasoning tokens are not added again to output. Unknown prices produce a `*` beside the partial estimate; tokens still count. Today uses the local calendar, 7/30 days are rolling windows, and the sparkline shows seven calendar days.

Local state lives in `~/Library/Application Support/Gauge`: last successful usage, pricing, file cursors, and recent token events. Caches contain timestamps, model names, local log paths, and token counts, but no conversation text or credentials. Files are private to the current user. On the first statistics pass, Gauge also imports retained events for already-deleted logs from `~/Library/Caches/swiftbar-codex-estimate.json`, if present. The original SwiftBar cache is left untouched.

## Validation

```sh
swift build -c release
./scripts/build.sh
codesign --verify --strict build/Gauge.app
build/Gauge.app/Contents/MacOS/Gauge --diagnose
```

`--diagnose` checks live usage and local estimates without starting the UI or registering a login item. It prints only usage percentages and aggregate statistics, and refreshes Gauge's local caches. No test suite is included.

## Credits

The menu bar OpenAI mark is the CC0 Simple Icons v14 alpha mask included in the original `codex-usage.1m.py` plugin. The application icon is drawn by `scripts/make-icon.swift`. Gauge is an independent utility.
