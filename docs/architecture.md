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

Multiple Macs may collect different local account subsets while signed into the
same iCloud account. Credentials and account setup remain local to each Mac, but
the CloudKit companion publisher merges the shared `current-v2` document by
sanitized provider/account identity before saving. Newer healthy account data
replaces the same account, accounts not reported by that Mac remain available,
and a degraded or unauthenticated collector cannot erase healthy lanes published
by another Mac. Companion truth is selected per logical account observation,
not from the worst collector attempt: a failed attempt does not advance the
observation timestamp, and a matching saved value remains available without
sharing that Mac's credential failure. Status-only failures are omitted when
another Mac has usable data for the provider. CloudKit change tags and conflict
retries protect concurrent publishers. Preserved observations retain their
original timestamps so companion clients can mark only those lanes stale instead
of presenting them as freshly collected. Fresh lanes keep the companion ready;
saved lanes remain visible but do not participate in pooled capacity or burn
forecasts while current lanes are available. When every lane is saved, constrained
glance surfaces may preserve the complete last-known pool as explicitly stale
context rather than inventing a partial current total. A versioned usage record isolates this behavior from older
whole-document publishers; current clients also read and merge the legacy record
during rollout so an older Mac can contribute data without erasing the versioned
account set.
After each authoritative `current-v2` save, current publishers mirror the merged
document to legacy `current`. That mirror remains a compatibility wake channel
for the Production-promoted CloudKit subscription and for older clients; it is
not the authoritative multi-Mac source of truth.

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
  OAuth, Antigravity Keychain access, and private Cloud Code Assist requests are
  removed. AGY invokes the signed refresh agent through its documented custom
  status-line command. The utility mode strictly extracts version, plan tier,
  and quota buckets from bounded standard input, then atomically writes a
  sanitized App Group snapshot for the normal connector runtime.
- Claude provider: store Context Panel-owned Claude OAuth tokens, refresh them
  through Anthropic's OAuth token endpoint when needed, call the Claude OAuth
  usage endpoint, and normalize returned utilization windows into reported
  percentages. Legacy Claude Code status-line/cache paths are not runtime data
  sources.

Connector implementations must keep secrets out of normalized state. Do not
persist or print tokens, raw account IDs, project IDs, organization IDs,
headers, or raw response bodies. A user-facing account display label may be
stored in normalized snapshots, including an email address when that is the
provider or user-selected label, but it must stay out of logs and diagnostics.
Errors should mention status and operation but not provider response content.

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

A healthy account configuration with no enabled accounts is authoritative. If
provider state was previously stored, the refresh service writes and publishes
an empty snapshot rather than treating the refresh as a no-op. That clears stale
app, widget, companion, reset-retry, warning, webhook, and pending-notification
lanes while preserving generic no-report skips for unexpected connector output.

Refresh diagnostics are persisted as redacted App Group JSON so Settings can
show the last app or agent refresh decision, provider failure counts, limit
warning evaluation, and local/webhook alert delivery breadcrumbs. The record is
support-oriented state rather than a provider payload archive: it stores only
summaries, timestamps, HTTP status codes, and redacted errors.

The app, widget, and refresh agent share durable state through the
`MM5YXC7T6E.group.com.shinycomputers.contextpanel` App Group. The account configuration
store keeps non-secret connector settings in that group container so the login
item can refresh data after the main app exits. Provider tokens and raw account
identifiers stay outside normalized snapshots and logs. User-facing account
labels remain display data rather than authentication identity.

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
reads on iPhone, iPad, and visionOS. The legacy iCloud Drive companion document
is no longer part of the default companion runtime load path; recovery should
come from a fresh Mac publish to CloudKit or the existing local app-group mirror.
CloudKit transport clients retain their `CKContainer` for the full client
lifetime so asynchronous record operations cannot outlive the underlying
CloudKit client.

The watchOS app and complication each read the same sanitized Production
CloudKit records directly. Each process caches the latest document and effective
display preferences in its own sandbox, so the complication can complete from a
last-good local value when CloudKit is delayed or unavailable. Opening the Watch
app invalidates the complication timeline whenever it has a usable document,
including a confirmed local-cache value after an app update, and the timeline
includes a future stale transition. Successful Watch CloudKit reads merge with
the process-local cache per account observation rather than choosing a whole
document by its envelope timestamp. The watch app requests one kind-specific
timeline reload after every usable refresh because its cache cannot reveal
whether the complication's separate cache has converged. The watch app list
follows the synced saved main-limit visibility and order instead of promoting
auxiliary provider buckets.
The watch targets do not
depend on App Group storage because physical TestFlight validation on watchOS 27
rejected otherwise valid App Group entitlements at runtime.
When any cached lane in a multi-account limit becomes stale or unavailable,
Watch presentation preserves the complete pooled last-known capacity and labels
it stale instead of recalculating from only the remaining current lanes or
falling back to one exhausted account.

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

The tvOS app registers both its CloudKit subscription and APNs delivery on
launch and foreground activation. Failed registration remains a recoverable
state: the app retries when it becomes active, preserves foreground refresh, and
never stores or logs the APNs device token. The query subscription uses the
Production-promoted `companion-sync-updates` contract and matches the legacy
`current` wake record. Registration fetches that subscription first and creates
it only when it is missing. The `v2` and `v3` subscription IDs are deliberately
left in place during the internal rolling-upgrade bridge so older builds do not
lose their wake channel. App handlers accept only their own generation's wake
notification, then reload and merge `current-v2` with legacy `current`.
Roll out the bridge publisher first: the replacement Mac writes both records,
so existing `v3` companions and replacement `current` companions continue to
receive wakes while device updates propagate.

CloudKit does not allow a new subscription definition to be introduced directly
from a Production runtime. Any future subscription ID or predicate change must
first be created in Development and included in the CloudKit schema deployment
to Production before a TestFlight or App Store build starts using it.
Do not deploy the abandoned `v3` definition while the legacy-wake bridge is the
release contract.

Provider detail keeps the saved primary limit as the dominant answer while it
has current capacity. If that lane is temporarily unavailable, detail promotes
an available capacity lane and renders the missing lane as a compact supporting
row. Full Detail shows safe account labels and exact capacity; Hide Account Names
keeps the same per-account percentage, status, and reset rows with provider-scoped
anonymous labels reused across windows. Distinct model sublimits remain separate
without exposing account identity. Lane summaries and metric rows are static focus targets so Siri Remote
navigation can scroll long detail screens without implying an action. The
approved three-provider overview remains a separate stable surface.

Top Shelf is a separate TVServices extension with no provider or CloudKit
network authority. The containing tvOS app projects its current snapshot and
device-local presentation mode into a purpose-built, privacy-filtered document
under `Library/Caches` in the existing companion App Group, then asks the system
to reload Top Shelf. Keeping this derived document inside the app-group Library
domain preserves current-user access on physical tvOS while avoiding backup of
ephemeral runway data. The extension reads that document immediately and
generates provider cards in the same App Group cache so the Home Screen can read
the returned image URLs; missing and stale documents remain
explicit rather than blocking the shelf on network work. The extension presents
those cards as one inset portfolio hero so every provider
is visible at a glance with one privacy-safe runway action. tvOS displays this
dynamic surface only while the Context Panel tile is focused in the Home Screen's
top row; the app tile's icon, name, placement, and focus treatment remain
system-controlled. CloudKit content-available pushes are handled only by
the containing app as a best-effort refresh path and never replace foreground
refresh or visible freshness labels. Both the app and extension run as the
current Apple TV user so CloudKit, preferences, and the shared Top Shelf cache
remain isolated when household profiles change. The app accepts only the known
CloudKit subscription, rejects notifications owned by a different current user,
and accepts a missing container field only because CloudKit may prune that
nullable payload metadata. Fresh Top Shelf items expire at the shared snapshot
freshness deadline so system-cached cards cannot continue presenting current
copy after their source becomes stale. Background completion uses an unstructured
deadline so a non-cooperative network request cannot hold the system callback
open indefinitely.

tvOS provider attention remains part of the app and Top Shelf runway rather than
the app icon badge. Physical tvOS 27 validation showed that the system accepts a
badge-only local expiry request but does not reliably deliver it while the app is
suspended. A badge could therefore outlive the snapshot that justified it and
present stale status as current. The tvOS app requests no badge permission,
schedules no local badge notification, and clears the retired badge, preference,
pending request, and device-local alert state when an upgraded app launches.
No account identifiers, account names, provider responses, or error payloads
are written to the Top Shelf document.

Limit warnings are evaluated from normalized `MainLimitSummary` capacity, not
raw provider payloads. Local macOS notifications and outbound webhooks use
separate delivery state so one channel cannot suppress the other. Webhook
settings and delivery status live in the App Group as non-secret JSON, while the
webhook URL is treated as a capability secret and stored in Keychain. Webhook
payloads must contain only normalized warning data such as provider, main-limit
window, percent remaining, remaining/limit values, reset time, and app version.
They must not include account IDs, emails, provider organization/project IDs,
auth paths, prompts, raw provider responses, tokens, or the webhook URL itself.
Webhook destinations must be non-local HTTPS URLs. Explicit loopback, private,
link-local, multicast, and reserved address forms are rejected. Redirects are
accepted only for same-origin 307/308 responses so the warning POST method and
body are preserved. Regular DNS hostnames remain subject to the operating
system's DNS resolution.
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
Antigravity setup stores no credential or external path: AGY publishes a
privacy-filtered quota observation into Context Panel's App Group through the
signed refresh agent. Claude usage uses Context Panel-owned OAuth credentials
stored in Keychain.

Widget interactions should keep the widget simple. Tapping the widget should
open the app to the relevant provider or account detail; mutation and setup stay
inside the app.
