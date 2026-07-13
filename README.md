# Context Panel

Context Panel is a native macOS app and WidgetKit extension for seeing AI usage
limits across providers at a glance. The first target providers are OpenAI,
Anthropic, and Google.

The product goal is a small, native Mac utility that can answer the everyday
question before you prompt: which accounts and models are still available,
which limits are close, and when each allowance resets.

## Current Status

This repository now includes the native macOS app, WidgetKit extension,
background refresh agent, companion targets, shared provider/usage-limit domain
modules, CI, release workflows, and repository workflow metadata. Active work is
focused on provider connectors, account setup, widget/app polish, release
validation, and production-quality diagnostics.

## Product Direction

- Native macOS first, with WidgetKit as the primary glanceable surface.
- A companion app for account setup, provider connection health, and deeper
  usage detail.
- Multiple logins per provider, because friends, work accounts, personal
  accounts, and team accounts all need to coexist.
- Provider-neutral usage state for OpenAI, Anthropic, Google, and later services.
- Local-first handling of account credentials and usage snapshots.
- Beautiful compact charts and state widgets that emphasize remaining capacity,
  reset time, and trend instead of billing-dashboard noise.
- Small enough to share with friends without setup becoming a project.

## Planned Experience

The widget should be useful at a glance: provider/account rows, remaining usage,
reset timing, and compact visual indicators such as rings, bars, sparklines, or
small multiples when they make the state easier to read.

Clicking the widget should open the native app. The app is the place for account
setup, provider-specific status, refresh history, raw limit details, charts over
time, and troubleshooting when a provider changes behavior.

## Local Setup

```sh
swift build
swift test
scripts/commit-gate.sh
```

Useful entry points:

- [Product Goals](docs/product-goals.md)
- [Architecture](docs/architecture.md)
- [macOS Release Path](docs/release.md)
- [Repository Settings](docs/repo-settings.md)

## Local App Bundle

To build the native macOS app with the embedded WidgetKit extension:

```sh
xcodegen generate --spec project.yml
xcodebuild \
  -project ContextPanel.xcodeproj \
  -scheme ContextPanel \
  -configuration Debug \
  -destination 'platform=macOS' \
  -allowProvisioningUpdates \
  build
```

To build a quick launchable macOS app bundle from the SwiftPM app shell:

```sh
scripts/package-macos-app.sh --output dist --identity auto
open "dist/Context Panel.app"
```

When a Developer ID Application identity is available in Keychain, the script
uses it through `codesign`; otherwise it falls back to ad-hoc signing. This is
the interim friend-installable path for the app shell only; use the Xcode build
when testing the widget extension.

To build the native release artifact locally, including the widget extension:

```sh
scripts/package-native-macos-app.sh --version 1.0.0 --output dist --identity auto
```

GitHub Actions also has a `Release` workflow for tag or manual releases. Without
Apple signing secrets it publishes an ad-hoc signed validation artifact; with
Developer ID and notarization secrets it can produce the friend-installable
release artifact.

## Local Provider Probes

The package includes development probes for validating provider limit signals
without printing secrets or raw provider responses:

```sh
swift run CodexRateLimitProbe --auth ~/.code/auth_accounts.json
swift run SnapshotStoreProbe --codex-auth ~/.code/auth_accounts.json
```

The Codex probe can return live percent-window quota buckets for CLI-backed
OpenAI accounts. The retired Gemini CLI / legacy Code Assist probe and Claude
status-line probe have been removed. Claude limits are refreshed through the
Context Panel-owned Claude OAuth usage connector.

For Google Antigravity, Context Panel uses AGY's documented custom status-line
command as an opt-in local bridge. The signed refresh agent accepts only the
documented quota allowlist, writes a sanitized App Group snapshot, and never
reads Antigravity credentials or calls private Google quota endpoints. Bridge
data updates while AGY CLI runs and becomes explicitly stale when it is no
longer current. AGY supports one custom status-line command, so setup is guided
and never overwrites or chains an existing customization automatically.

The probes call the same `ContextPanelCore` connectors the app will use, so
passing probe output is also a smoke test for the production connector runtime.
`SnapshotStoreProbe` additionally writes and reloads the local JSON cache shape
that the app and widget will consume.
