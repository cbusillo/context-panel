# Context Panel

Context Panel is a native macOS app and WidgetKit extension for seeing AI usage
limits across providers at a glance, with read-only iPhone, iPad, Vision Pro,
Apple Watch, and Apple TV companions. It supports OpenAI, Anthropic, and
Google.

The product goal is a small, native Mac utility that can answer the everyday
question before you prompt: which accounts and models are still available,
which limits are close, and when each allowance resets.

## Direction and Contributions

See the Director's [overall DIRECTION.md](https://github.com/cbusillo/direction/blob/HEAD/DIRECTION.md)
and [AGENTS.md](AGENTS.md) for direction and repository guidance, and
[the release procedure](docs/release.md) for release operations.

## Product Experience

- Native macOS first, with WidgetKit as the primary glanceable surface.
- The Mac app for account setup, provider connection health, and deeper
  usage detail.
- Multiple logins per provider, because friends, work accounts, personal
  accounts, and team accounts all need to coexist.
- Provider-neutral usage state for OpenAI, Anthropic, and Google.
- Local-first handling of account credentials and usage snapshots.
- Beautiful compact charts and state widgets that emphasize remaining capacity,
  reset time, and trend instead of billing-dashboard noise.
- Small enough to share with friends without setup becoming a project.

## App and Widget

The accepted [Horizon design](docs/design-direction.md) makes the account the
unit on every surface. Account rows show remaining capacity, observed burn,
when an account runs out, and how much it has to spare at its reset.

Clicking the widget should open the native app. The app is the place for account
setup, provider-specific status, refresh history, raw limit details, charts over
time, and troubleshooting when a provider changes behavior.

## Local Setup

```sh
swift build
swift test --filter '{test_filter}'
```

[Test rules](AGENTS.md#test-rules) and [test lanes](docs/test-lanes.md) explain
focused local selection and the complete CI sequence in `.github/github.json`.

Useful entry points:

- [Product Goals](docs/product-goals.md)
- [Architecture](docs/architecture.md)
- [macOS Release Path](docs/release.md)
- [Repository Settings](docs/repo-settings.md)

## Local App Bundle

`ContextPanel.xcodeproj` is generated from `project.yml` and is not committed.
Run `xcodegen generate --spec project.yml` before opening the project in Xcode;
every build script does the same. Change targets, settings, and schemes in
`project.yml`, never in the generated project.

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

Build outputs are intermediate artifacts. Testing app/widget runtime, login-item,
provider, sandbox, and storage behavior through an app bundle uses only
`/Applications/Context Panel.app`.
Shared-view captures follow [the validation authority](docs/validation-authority.md).
For a Development runtime, use the in-place install gate:

```sh
scripts/context-panel-runtime-baseline.sh install --launch
```

If the installed app is signed Production, TestFlight, or App Store, preserve it
and use the read-only check instead:

```sh
scripts/context-panel-runtime-baseline.sh check --require-production-runtime
```

Follow [the runtime requirements](docs/validation-authority.md#validation) before judging
behavior or reporting readiness, including active process, widget registration,
refresh-agent, URL-handler, fingerprint, and real WidgetKit cache evidence.
Signed companion validation also requires the companion cache preflight.

Packaging and distribution use [the release procedure](docs/release.md), including
version/build inputs, signing, the CloudKit schema gate, and release gates.
The `Release` workflow runs from `main` through manual dispatch or `Ship`;
creating a tag does not start it, and merging a PR does not publish a release.
Release closeout follows the [definition of released](docs/release.md#definition-of-released).

## Local Provider Probes

The package includes development probes for validating provider limit signals
without printing secrets or raw provider responses:

```sh
swift run CodexRateLimitProbe --auth ~/.codex/auth.json
swift run CodexRateLimitProbe --auth "/path/to/account-home/auth.json"
swift run SnapshotStoreProbe --codex-auth "/path/to/account-home/auth.json"
```

The Codex probe can return live percent-window quota buckets for CLI-backed
OpenAI accounts. The retired Gemini CLI / legacy Code Assist probe and Claude
status-line probe have been removed. Claude limits are refreshed through the
Context Panel-owned Claude OAuth usage connector.

Agents can read the panel's saved account view without credentials:

```sh
swift run ContextPanelAccountSnapshot
```

This read-only command emits versioned JSON from the canonical App Group store.
It includes configured accounts that are disconnected, unavailable, disabled or
stale, per-window usage/burn/natural resets, and reported banked resets. It does
not refresh providers or change configuration. Unknown observations stay null;
optional fields within provider summaries may be absent. A saved `accounts.json`
is required. Inspect
each account's state and observation time before relying on its capacity. See the
[agent snapshot contract](docs/provider-usage-access.md#agent-readable-account-snapshot).

For Google Antigravity, Context Panel uses an opt-in AGY Stop hook to run
`agy -p "/usage" --output-format json` after interactive and headless runs.
Copy Setup in the Google account settings supplies one command to paste into
Terminal; the command installs the named hook. Restart existing AGY sessions. Copy
Remove removes only that hook. The signed refresh agent directly reads the
bounded, validated quota JSON, saves only a sanitized App Group snapshot, and
immediately publishes Google readings. It never reads AGY credentials or calls
private Google endpoints. See the [connector setup and compatibility
proof](docs/provider-usage-access.md#google-antigravity-connector).
Idle time alone does not make a reading stale. After a scheduled reset,
`≈100%` means assumed capacity until the next run supplies an observation;
assumed capacity is not written to observed history.

The probes exercise shared `ContextPanelCore` connectors from the shell.
They do not prove signed app or refresh-agent behavior: sandbox access, TCC,
security-scoped bookmarks, app groups, and login-item environments differ.
Validate those reads through the canonical installed runtime as
[the runtime requirements](docs/validation-authority.md#validation) require. `SnapshotStoreProbe` additionally writes
and reloads the local JSON cache shape used by the app and widget.
