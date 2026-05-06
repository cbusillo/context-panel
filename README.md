# Context Panel

Context Panel is a planned macOS app and widget for seeing AI usage limits
across providers at a glance. The first target providers are OpenAI, Anthropic,
and Google.

The product goal is a small, native Mac utility that can answer the everyday
question before you prompt: which accounts and models are still available,
which limits are close, and when each allowance resets.

## Current Status

This repository is a native starter shell. It currently includes a Swift package
for shared provider and usage-limit domain types, CI, Dependabot, and repository
workflow metadata. The macOS app and widget targets will be added once the first
data and UI contracts settle.

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
- [Repository Settings](docs/repo-settings.md)

## Local Provider Probes

The package includes development probes for validating provider limit signals
without printing secrets or raw provider responses:

```sh
swift run CodexRateLimitProbe --auth ~/.codex/auth.json
GEMINI_OAUTH_CLIENT_ID=... GEMINI_OAUTH_CLIENT_SECRET=... \
  swift run GeminiQuotaProbe --auth ~/.gemini/oauth_creds.json
swift run ClaudeLimitProbe
swift run SnapshotStoreProbe --codex-auth ~/.codex/auth.json --include-claude
```

The Codex and Gemini probes can return live percent-window quota buckets for
their respective CLI-backed accounts. The Claude probe intentionally reports
local auth/subscription metadata and local stats-cache freshness until a Claude
Code status-line cache has been populated.

To capture Claude subscription usage percentages, configure Claude Code's
status line to call the helper in this repo. Claude Code sends the helper a JSON
payload after session responses; the helper stores only five-hour and weekly
used percentages plus reset timestamps under Context Panel's Application
Support directory.

```json
{
  "statusLine": {
    "type": "command",
    "command": "/absolute/path/to/context-panel/scripts/claude-statusline-cache.sh"
  }
}
```

The helper does not store auth tokens, prompts, transcript contents, emails,
organization IDs, or raw Claude session JSON. Claude Code's non-interactive
`claude -p` path does not appear to run the status-line hook, so Context Panel
marks old Claude subscription readings stale instead of treating them as live.

For Gemini, use the OAuth client values from the locally installed Gemini CLI;
they are intentionally not checked into this repository.

The probes call the same `ContextPanelCore` connectors the app will use, so
passing probe output is also a smoke test for the production connector runtime.
`SnapshotStoreProbe` additionally writes and reloads the local JSON cache shape
that the app and widget will consume.
