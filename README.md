# Context Panel

Context Panel is a native macOS app and WidgetKit extension for seeing AI usage
limits across providers at a glance, with read-only iPhone, iPad, Vision Pro,
Apple Watch, and Apple TV companions. It supports OpenAI, Anthropic, and
Google.

The product goal is a small, native Mac utility that can answer the everyday
question before you prompt: which accounts and models are still available,
which limits are close, and when each allowance resets.

## Direction and Contributions

The Director's [overall DIRECTION.md](https://github.com/cbusillo/direction/blob/HEAD/DIRECTION.md)
governs priorities and stop boundaries. This repository has no DIRECTION.md of
its own. [AGENTS.md](AGENTS.md) is the only agent-instruction file and owns the
repository's execution and validation guidance. Durable work is tracked in
GitHub issues.

Contributions use focused branches and pull requests. Authorized changes land
with a normal merge commit after green CI and required checks; this repository
does not use the Launchplane merge train. Reviews by another model follow the
[shared review reference](https://github.com/cbusillo/codex-skills/blob/main/skills/references/model-review.md):
findings are weighed against evidence, rather than reviewer approval being a
gate. Releases are separate from merging and follow [the release procedure](docs/release.md).

## Product Experience

- Native macOS first, with WidgetKit as the primary glanceable surface.
- A companion app for account setup, provider connection health, and deeper
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
when an account runs out, and how much it has to spare at its reset. The older
limit-based layout remains available as the **Windows** widget layout in Display
settings.

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

Build outputs are intermediate artifacts. Local app/widget runtime, login-item,
provider, sandbox, and storage testing use only `/Applications/Context Panel.app`.
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

Follow [AGENTS.md's runtime requirements](AGENTS.md#validation) before judging
behavior or reporting readiness, including active process, widget registration,
refresh-agent, URL-handler, fingerprint, and real WidgetKit cache evidence.
Signed companion validation also requires the companion cache preflight.

Packaging and distribution use [the release procedure](docs/release.md), including
version/build inputs, signing, CloudKit schema receipts, and release gates.
The `Release` workflow runs from `main` through manual dispatch or `Ship`;
creating a tag does not start it, and merging a PR does not publish a release.

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

For Google Antigravity, Context Panel uses AGY's documented custom status-line
command as an opt-in local bridge. The signed refresh agent accepts only the
documented quota allowlist, writes a sanitized App Group snapshot, and never
reads Antigravity credentials or calls private Google quota endpoints. Bridge
data updates while AGY CLI runs. Idle time alone does not make the last
observation stale. After an explicit reset passes, Context Panel preserves the
last observation internally while presenting `≈100%` remaining and `≈0%` used
as an assumed reset until the next AGY run confirms the new window. Assumed
capacity is not written into observed history or treated as high-confidence
forecast evidence. AGY supports one custom status-line command, so setup is
guided and never overwrites or chains an existing customization automatically.
Historical AGY 1.1.1 compatibility was verified against a non-interactive
`agy --add-dir <workspace> -p <prompt>` execution: the configured callback
publishes the documented quota payload even though no separate interactive AGY
session is running.

The probes exercise shared `ContextPanelCore` connectors from the shell.
They do not prove signed app or refresh-agent behavior: sandbox access, TCC,
security-scoped bookmarks, app groups, and login-item environments differ.
Validate those reads through the canonical installed runtime as
[AGENTS.md](AGENTS.md#validation) requires. `SnapshotStoreProbe` additionally writes
and reloads the local JSON cache shape used by the app and widget.
