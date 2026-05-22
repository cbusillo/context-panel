# Architecture

Context Panel is expected to split into a few native boundaries:

- `ContextPanelCore`: provider-neutral domain models, limit math, and refresh
  policy.
- Account store: multiple logins per provider, local credential references,
  display names, and enabled/disabled state.
- Provider adapters: small clients that retrieve or normalize usage state for
  each service without leaking provider quirks into the UI.
- Snapshot store: the latest normalized usage state plus refresh history for
  widgets and charts.
- macOS app: account setup, credentials, manual refresh, detailed charts,
  provider health, and settings.
- Refresh agent: a bundled native login item that performs periodic provider
  refreshes when the app UI is not running.
- Widget extension: compact read-only display backed by the app's latest local
  snapshot.

The shared vocabulary now lives in `ContextPanelCore`. App, widget, probes, and
the background refresh agent all consume the same normalized provider reports,
account configuration, snapshots, main-limit summaries, and forecast math.

## Domain Model

`UsageLimit` is the normalized provider/account/window bucket. It carries the
provider, local redacted account identity, display account name, model/window
labels, unit, used and total values when known, reset time, freshness,
confidence, and an explicit degraded status. Unknown limits and provider
failures stay representable instead of being collapsed into zero capacity.

`UsageSnapshot` is the provider-neutral aggregate consumed by storage and UI.
It can contain multiple accounts per provider and multiple limit buckets per
account. Provider-specific adapters are responsible for converting live data
into this shape; UI code should not depend on raw provider response fields.

`MainLimitSummary` groups interchangeable headline windows by provider and
window, such as OpenAI weekly, Anthropic 5-hour, or Google daily. Inside a
summary, compatible account buckets are pooled for used, total, remaining, and
status math so one exhausted interchangeable account does not become the whole
provider headline. The original account rows remain available for detail views.
Summaries also expose a `CapacityPool` for reset-aware runway calculations and
sample-relative reset helpers for history analysis.

`WidgetSnapshot` is the compact projection of a stored snapshot plus history.
It owns staleness, setup-needed state, provider summaries, observed burn-rate
estimates, and OpenAI fast-mode forecast selection before the SwiftUI widget
views render anything.

## Connector Runtime

`ContextPanelCore` owns the provider connector contract. A connector refreshes
one or more configured local accounts and returns a `ConnectorRefreshResult`,
which carries provider/account reports plus a normalized `UsageSnapshot` for UI
and storage code.

MVP connectors:

- `CodexRateLimitConnector`: reads Codex-style auth roots such as `~/.code` or
  `~/.codex`, calls the live Codex usage endpoint, and normalizes primary,
  secondary, and additional percent-window buckets.
- `GeminiCodeAssistConnector`: reads Google coding-tool credentials from
  Antigravity Keychain sign-in or Gemini CLI OAuth credentials, resolves the
  active Code Assist project internally, and normalizes model quota buckets as
  percent pressure.
- `ClaudeLocalStatusConnector`: runs `claude auth status --json` and summarizes
  `~/.claude/stats-cache.json`; live personal subscription allowance remains
  unknown unless a clean provider signal appears.

Connector implementations must keep secrets out of normalized state. Do not
persist or print tokens, account IDs, project IDs, organization IDs, emails,
headers, or raw response bodies. Errors should mention status and operation but
not provider response content.

## Snapshot Store

The MVP cache is a local JSON store. It writes one current snapshot file plus a
history directory of timestamped snapshots. The schema is intentionally simple:
`StoredUsageSnapshot` includes a schema version, save time, normalized
`UsageSnapshot`, and redacted provider refresh reports.

The widget should read `current-snapshot.json` and apply a staleness policy. It
must not read provider credential files or make provider network calls. The app
and the refresh agent own connector refreshes through the same
`SnapshotRefreshService` in `ContextPanelCore`; account setup, diagnostics, and
future migration from JSON to a richer store stay in the app.

The app, widget, and refresh agent share durable state through the
`MM5YXC7T6E.group.com.shinycomputers.contextpanel` App Group. The account configuration
store keeps non-secret connector settings in that group container so the login
item can refresh data after the main app exits. Provider tokens and raw account
identifiers stay outside normalized snapshots and logs.

`ContextPanelRefreshAgent` is embedded in the native app under
`Contents/Library/LoginItems` and registered by the main app with
`SMAppService`. The agent has the same App Group entitlement as the app and
widget so it can write the shared snapshot store while the main app is not
running. It imports `ContextPanelCore` and uses `SnapshotRefreshRunner`, keeping
provider checks DRY across app-initiated and background refreshes. A simple
file lock in the App Group snapshot directory prevents the app and agent from
writing overlapping refresh results.

The WidgetKit implementation uses a `WidgetSnapshot` projection from the stored
snapshot. That projection owns setup-needed, stale, failure, provider-summary,
and most-constrained row selection so the widget view stays read-only and small.

OpenAI fast-mode guidance is built from the same `MainLimitSummary` values used
elsewhere. Weekly capacity is treated as the primary pool and shorter windows,
such as 5-hour limits, are guardrails rather than replacement headlines. Burn
rates are estimated from snapshot history when enough samples exist and skip
intervals that cross resets.

## Account Configuration

The MVP account configuration is also local JSON. It stores account labels,
enabled/disabled state, connector kind, and local paths or command names needed
to locate provider CLI auth. It does not store provider secrets. Google usage can
use Antigravity's Keychain token when present; Gemini OAuth client inputs are
referenced by environment variable names so the values can remain outside the
repository and outside the account config file.

Widget interactions should keep the widget simple. Tapping the widget should
open the app to the relevant provider or account detail; mutation and setup stay
inside the app.
