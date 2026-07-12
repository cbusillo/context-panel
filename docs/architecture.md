# Architecture

Context Panel is expected to split into a few native boundaries:

- `ContextPanelCore`: provider-neutral domain models, limit math, and refresh
  policy.
- `ContextPanelWidgetUI`: reusable SwiftUI glance presentation for widget-sized
  limit summaries. It consumes normalized snapshots and display preferences but
  does not own WidgetKit timelines, local stores, provider refresh, or platform
  storage roots.
- `ContextPanelSettingsUI`: portable, value-driven SwiftUI controls for
  companion-safe presentation settings. It depends only on `ContextPanelCore`
  and emits user intent through closures; app-group storage, widget reloads,
  sync, permissions, credentials, and provider administration stay in the host
  app models.
- Account store: multiple logins per provider, local credential references,
  display names, and enabled/disabled state.
- Provider adapters: small clients that retrieve or normalize usage state for
  each service without leaking provider quirks into the UI.
- Snapshot store: the latest normalized usage state plus refresh history for
  widgets and charts.
- macOS app: account setup, credentials, manual refresh, detailed charts,
  provider health, and settings.
- Refresh agent: a bundled native login item that performs periodic provider
  refreshes when the app UI is not running. It evaluates local limit-warning
  thresholds but queues pending local notifications for the main app to deliver
  under the app's notification authorization.
- Widget extension: compact read-only display backed by the app's latest local
  snapshot.
- tvOS app: a separate read-only couch-distance runway surface backed by the
  sanitized CloudKit companion document and a last-good local cache. It does
  not link WidgetKit, provider connectors, credentials, or collector controls.
- Optional outbound webhook channel: user-configured limit-warning delivery to
  a third-party URL, with secrets stored in Keychain and normalized payloads
  built from `LimitWarningEvent`.

Local limit-warning notifications use app-group state. The refresh agent records
warning state and writes pending notification events to shared storage, then
wakes the running app with a distributed notification. The main app drains that
queue through `UNUserNotificationCenter`, so macOS authorization stays attached
to the user-facing app bundle rather than the background login item.

The shared vocabulary now lives in `ContextPanelCore`. App, widgets, Watch,
tvOS, probes, and the background refresh agent all consume the same normalized
provider reports, account configuration, snapshots, main-limit summaries,
display preferences, main-answer selection, and forecast math. The shared
selection keeps the first visible saved limit stable, identifies an optional
distinct closest limit, and preserves supporting saved order; platform targets
still own their native layout and interaction. Missing saved limits remain
explicit placeholders, an all-hidden selection remains empty, and auxiliary
provider limits stay in detail surfaces instead of replacing the stable answer.

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
Live capacity math excludes failed, stale, unknown, expired, or shorter-window
buckets blocked by an exhausted longer window on the same account. Summaries
also expose a `CapacityPool` for reset-aware runway calculations and
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
- Google provider: retired Gemini CLI credential files, Context Panel Google
  OAuth, and local metadata discovery are removed. The Antigravity adapter
  follows the OpenAI/Codex local-auth pattern: read Antigravity's local Keychain
  login once per refresh, let Antigravity own sign-in and token refresh,
  discover the active project through `loadCodeAssist`, and call
  `retrieveUserQuota` for reported quota buckets.
- Claude provider: store Context Panel-owned Claude OAuth tokens, refresh them
  through Anthropic's OAuth token endpoint when needed, call the Claude OAuth
  usage endpoint, and normalize returned utilization windows into reported
  percentages. Legacy Claude Code status-line/cache paths are not runtime data
  sources.

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

Refresh diagnostics are persisted as redacted App Group JSON so Settings can
show the last app or agent refresh decision, provider failure counts, limit
warning evaluation, and local/webhook alert delivery breadcrumbs. The record is
support-oriented state rather than a provider payload archive: it stores only
summaries, timestamps, HTTP status codes, and redacted errors.

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
and most-constrained row selection. `ContextPanelWidgetUI` renders the shared
small, medium, and large glance layouts, while the macOS widget extension owns
the timeline provider, family mapping, widget URL wiring, local App Group store,
and widget-container fallback behavior. Widget timelines include a future entry
at the earliest snapshot-age or provider-reset freshness deadline so WidgetKit
cannot keep an old healthy presentation indefinitely when the system delays the
next extension refresh.

`CompanionSnapshot` is the transport-neutral projection for Apple companion
clients such as iPhone, iPad, visionOS, watchOS, and tvOS. It is constructed from a
stored local snapshot but intentionally omits raw account IDs, configured account
IDs, local notes, auth paths, provider error strings, webhook secrets, tokens,
and raw provider responses. Companion sync transports must publish this safe
projection or a stricter descendant, not `StoredUsageSnapshot`.

CloudKit is the remote companion transport. Companion apps load the
Mac-published CloudKit record when available and mirror the sanitized companion
document into their local App Group store for app launch and WidgetKit timeline
reads. The legacy iCloud Drive companion document is no longer part of the
default companion runtime load path; recovery should come from a fresh Mac
publish to CloudKit or the existing local app-group mirror.

Widget display preferences use one-way defaults plus local companion ownership.
The Mac continues publishing its preferences in `CompanionSyncDocument` for
backward compatibility and as the initial companion fallback. Once a companion
changes lane visibility or order, that app-group override becomes authoritative
for the companion app and its widgets only. Companion edits never flow back to
the Mac, so there is no bidirectional conflict resolution or collector/admin
mutation path.

The tvOS companion is a standalone target rather than another destination on
the iOS/visionOS app. It reuses `ContextPanelCore` and
`ContextPanelCloudKitSync` through tvOS-specific static-library wrappers, while
its focus-driven ten-foot UI remains isolated from WidgetKit and touch-oriented
settings surfaces. The first slice refreshes on launch, foreground activation,
and explicit user action. Physical tvOS stores the last good companion document
and its matching CloudKit receipt under the app's `Library/Caches` container;
tvOS may purge that storage, so a missing cache remains an explicit setup state
rather than durable account configuration. Provider snapshot age and CloudKit
receipt age remain separate so stale usage and delayed delivery do not become
conflated.

Limit warnings are evaluated from normalized `MainLimitSummary` capacity, not
raw provider payloads. Local macOS notifications and outbound webhooks use
separate delivery state so one channel cannot suppress the other. Webhook
settings and delivery status live in the App Group as non-secret JSON, while the
webhook URL is treated as a capability secret and stored in Keychain. Webhook
payloads must contain only normalized warning data such as provider, main-limit
window, percent remaining, remaining/limit values, reset time, and app version.
They must not include account IDs, emails, provider organization/project IDs,
auth paths, prompts, raw provider responses, tokens, or the webhook URL itself.
The refresh agent may queue local warnings, but only the main app records local
notification delivery success after `UNUserNotificationCenter` accepts the
notification.

OpenAI fast-mode guidance is built from the same `MainLimitSummary` values used
elsewhere. Weekly capacity is treated as the primary pool and shorter windows,
such as 5-hour limits, are guardrails rather than replacement headlines. Burn
rates are estimated from live snapshot-history buckets when enough samples exist
and skip intervals that cross resets.

## Account Configuration

The MVP account configuration is also local JSON. It stores account labels,
enabled/disabled state, connector kind, and local auth-file paths only for
file-backed OpenAI/Codex accounts. It does not store provider secrets. Google
Antigravity uses Antigravity's local Keychain login at refresh time and does not
persist Antigravity tokens in Context Panel storage. Claude usage uses Context
Panel-owned OAuth credentials stored in Keychain.

Widget interactions should keep the widget simple. Tapping the widget should
open the app to the relevant provider or account detail; mutation and setup stay
inside the app.
