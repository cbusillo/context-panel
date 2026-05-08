# Context Panel Agent Notes

## Product Shape

Context Panel is a native macOS app plus WidgetKit extension for tracking AI
usage limits across providers. Treat multi-account support as a core product
requirement, not a later enhancement. The initial provider set is OpenAI,
Anthropic, and Google.

The widget is for glanceable state: remaining capacity, limit pressure, reset
time, and whether refreshes are healthy. The app is for setup and detail:
multiple logins, credential management, provider diagnostics, detailed charts,
history, and settings.

## Engineering Defaults

- Keep the repo native-first. Do not add web or Docker surfaces unless Chris
  explicitly asks for them.
- Prefer Swift, SwiftUI, WidgetKit, and Swift Package Manager.
- Keep provider-specific behavior behind adapters. Shared UI and storage should
  consume normalized provider/account/limit snapshots.
- Keep credentials local. Favor Keychain-backed storage for secrets and avoid
  logging tokens, account identifiers, or raw provider responses that may expose
  sensitive data.
- Model unknown and degraded states explicitly. Provider APIs and unofficial
  usage surfaces can change; the UI should make stale or partial data obvious.
- Design for multiple accounts per provider from the data model up through the
  widget layout.

## UX Direction

- The widget should be beautiful, dense, and calm: compact charts, rings, bars,
  sparklines, reset countdowns, and provider/account grouping where useful.
- For weekly or rolling account limits, include forecast language that helps the
  user decide whether higher-burn modes are safe before reset.
- Avoid making the widget a dashboard crammed into a rectangle. Put setup,
  troubleshooting, raw details, and long histories in the app.
- Clicking the widget should open the app to the most relevant provider/account
  detail.
- Prefer plain status language: available, close to limit, limited, unknown,
  stale, refreshing.

## Validation

Run the commit gate before publishing changes:

```sh
scripts/commit-gate.sh
```

For UI work, also run the native app/widget locally and inspect the actual macOS
presentation before calling the work ready.

For widget/app UI changes, the SwiftPM gate is not sufficient by itself. Also
regenerate the Xcode project when `project.yml` or source membership changes,
build the real Xcode app target, replace the installed development app, and
restart the app/widget extension:

```sh
xcodegen generate
xcodebuild -project ContextPanel.xcodeproj -scheme ContextPanel -configuration Debug -derivedDataPath .build/xcode-derived-signed build
pkill -9 -f '/Applications/Context Panel.app/Contents/MacOS/Context Panel' || true
pkill -9 -f 'ContextPanelWidgetExtension.appex' || true
rm -rf "/Applications/Context Panel.app"
ditto ".build/xcode-derived-signed/Build/Products/Debug/Context Panel.app" "/Applications/Context Panel.app"
open "/Applications/Context Panel.app"
```

Do not create backup copies of `/Applications/Context Panel.app` during normal
development installs.

The installed widget can still be older than the rebuilt app. Check
`pluginkit -m -A -D -vvv | rg contextpanel` and verify the registered extension
path. If WidgetKit is registered to an old DerivedData path, rebuild/register
that path or remove the stale registration before judging the widget.

The widget needs access to `group.com.shinycomputers.contextpanel`. A wildcard
Mac Team provisioning profile may not carry that app-group entitlement, which
can make the widget show a `current-snapshot.json` read error even while the app
can read data. For release, use a provisioning profile with the app group
enabled. For local development, prefer an ad-hoc-signed install over a wildcard
profile when testing the live widget. If building with `CODE_SIGNING_ALLOWED=NO`,
ad-hoc sign the app, extension, and debug dylibs with their entitlements before
installing. The app also mirrors the current snapshot to the widget extension
container as a local-development fallback. The app-side copy path is the widget
container under `~/Library/Containers`, while the widget reads it through its
sandbox-local Application Support directory; keep that split in mind when
debugging why the app and widget disagree.

## Repo Workflow

- Default branch: `main`.
- Work on focused branches and open pull requests.
- Keep `.github/github-repo-workflow.json` current when docs, validation gates,
  important workflows, or repo ownership assumptions change.
