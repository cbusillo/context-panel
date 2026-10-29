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
Change targets, settings, and schemes in `project.yml`, then follow the canonical
[local native build instructions](docs/release.md#build-the-native-app-and-widget).

Runtime checks, signed-build protections, and release gates are maintained in
[Validation Authority](docs/validation-authority.md#validation) and the
[release procedure](docs/release.md); those documents are the operator sources
of truth.

## Local Provider Probes

The package retains development-only probes that never print secrets and the
read-only saved-account snapshot command:

```sh
swift run CodexRateLimitProbe --auth ~/.codex/auth.json
swift run CodexRateLimitProbe --auth "/path/to/account-home/auth.json"
swift run SnapshotStoreProbe --codex-auth "/path/to/account-home/auth.json"
swift run ContextPanelAccountSnapshot
```

`SnapshotStoreProbe` writes and reloads a snapshot in the app/widget cache format
in a temporary directory by default (`--output` selects another directory).

The canonical contracts, installed-app snapshot route, Google
Antigravity connector setup, and current provider behavior are maintained in
[Provider Usage Access](docs/provider-usage-access.md). The historical OpenAI
visible-limit probe design and redaction boundaries are documented in
[Local Limit Probe Design](docs/local-limit-probe.md).
Shell probes do not prove [signed-runtime behavior](docs/validation-authority.md#validation).
