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
- macOS app: account setup, credentials, refresh scheduling, detailed charts,
  provider health, and settings.
- Widget extension: compact read-only display backed by the app's latest local
  snapshot.

The first committed code lives in `ContextPanelCore` so provider, account, and
UI work can share the same vocabulary from the start.

## Connector Runtime

`ContextPanelCore` owns the provider connector contract. A connector refreshes
one or more configured local accounts and returns a `ConnectorRefreshResult`,
which carries provider/account reports plus a normalized `UsageSnapshot` for UI
and storage code.

MVP connectors:

- `CodexRateLimitConnector`: reads Codex-style auth roots such as `~/.code` or
  `~/.codex`, calls the live Codex usage endpoint, and normalizes primary,
  secondary, and additional percent-window buckets.
- `GeminiCodeAssistConnector`: reads Gemini CLI OAuth credentials, uses
  explicitly supplied OAuth client inputs, resolves the active Code Assist
  project internally, and normalizes model quota buckets as percent pressure.
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
owns connector refreshes, account setup, diagnostics, and future migration from
JSON to a richer store if history queries become more complex.

The WidgetKit implementation uses a `WidgetSnapshot` projection from the stored
snapshot. That projection owns setup-needed, stale, failure, provider-summary,
and most-constrained row selection so the widget view stays read-only and small.

## Account Configuration

The MVP account configuration is also local JSON. It stores account labels,
enabled/disabled state, connector kind, and local paths or command names needed
to locate provider CLI auth. It does not store provider secrets. Gemini OAuth
client inputs are referenced by environment variable names so the values can
remain outside the repository and outside the account config file.

Widget interactions should keep the widget simple. Tapping the widget should
open the app to the relevant provider or account detail; mutation and setup stay
inside the app.
