# Signed Validation Runtime Receipts

Context Panel can collect privacy-safe proof that the exact signed process for a
surface executed and selected a particular sanitized presentation state. Runtime
receipts are diagnostic evidence only: they never claim that a human reviewed a
shared view or that the OS displayed final widget, complication, or Top Shelf
pixels.

Implemented writers cover these process boundaries:

- the app after it loads the snapshot used by the overview
- the WidgetKit extension from `getSnapshot` and `getTimeline`
- the refresh agent after one-shot and background refresh decisions
- the iOS and iPadOS companion app after it selects synced usage for the visible overview
- the iOS and iPadOS companion widget from its real snapshot and timeline callbacks
- the visionOS companion app and widget through the same shipping entry points,
  with distinct surface identity and effective appearance in the presentation digest
- the watchOS app after its bounded companion load selects the visible result
- the Watch WidgetKit extension from the real complication snapshot and timeline callbacks
- the tvOS app from the exact runway publication shown by the shipping app
- the dynamic Top Shelf extension from `loadTopShelfContent()` after it selects its final content or nil result

Validation sessions and receipts cross devices through two dedicated private
CloudKit record types. Extensions still write only to their local App Group;
the macOS app/refresh agent and the companion, Watch, and tvOS host apps mirror
sessions and drain those local queues. Receipt records never share the companion
snapshot record type, record names, or subscription.

## Receipt Contract

Every receipt is schema-versioned and has the single evidence class
`actual-runtime`. The Swift type cannot encode `shared-view` or
`os-composited-placement` evidence.

A receipt contains:

- surface, platform, artifact, and bundle identity
- marketing version, build number, embedded manifest ID, and contract fingerprint
- render, runtime, placement, and combined surface fingerprints
- the UUID from the Mach-O image actually loaded in the process
- validation session ID and expiration
- process-instance ID and process-local sequence number
- trigger and widget family or presentation mode
- selected source, state branch, and a closed redacted outcome
- a deterministic SHA-256 digest of the sanitized selected presentation
- the device-observed timestamp

The process-instance ID is an ephemeral random UUID shared by every recorder
created inside one process. It is not a device ID. The process-local sequence
preserves ordering when receipts are relayed later without pretending that clocks
across devices are synchronized.

The embedded `ContextPanelSurfaceManifest.json` is authoritative. A process does
not write when its requested surface is absent, its bundle identifier differs,
the manifest is malformed, or the active session targets another manifest ID.
It also reads `LC_UUID` from the loaded Mach-O header rather than the executable
file currently present at the bundle path. An extension process that survives an
in-place update therefore reports its old loaded UUID even if bundle resources
have been replaced. The validation coordinator must compare that UUID with the
expected archive evidence. This makes app-versus-extension build drift visible
without assuming that equal version strings identify equal artifacts.

## Privacy Boundary

Receipts never contain account names or IDs, credentials, provider payloads, raw
errors, device UDIDs, filesystem paths, or App Store Connect object IDs.

The CloudKit relay stores the existing receipt JSON as bytes plus only bounded
transport metadata: schema versions, random session/process identifiers,
surface, timestamps, sequence, receipt hash, and payload size. Deterministic
`runtime-receipt-<sha256>` record names make retry idempotent without introducing a
device identifier. The session and receipt record types have no subscriptions,
so receipt upload or extraction cannot trigger the companion snapshot update
loop.

Presentation digests are computed from a canonical sanitized structure. The
structure may include generated timestamps, provider type, closed status enums,
limit counts, coarse usage buckets, reset/update timestamps, confidence,
freshness modes, widget family, normalized lane visibility/order, and the lanes
selected for that widget family. Visible prompt-cache percentages/status and
sanitized fast-mode settings/forecast outputs are represented without their
account-keyed source identifiers. It excludes account identity, labels, notes,
messages, raw prompt-cache token values, bookmark paths, and raw error text. Only
the final digest is written to the receipt.

Companion presentation digests additionally include the closed delivery state,
whether a redacted sync error is visibly active, privacy-safe refresh-attention
provider categories, and the effective visionOS appearance. A setup or failure
screen with no selected companion document omits synthetic generated and
presentation timestamps so equivalent repeated executions remain rate-limitable.
Companion source identity is a separate closed receipt field; CloudKit, iCloud,
App Group, and local-cache selections remain distinct. Unsupported or missing
source metadata is recorded as `none` and cannot produce a successful outcome.

Watch receipts use the exact saved-lane selection rendered by the app or the
requested accessory family. A Watch companion deadline with no saved document
is recorded as unknown/degraded rather than a false runtime failure. A deadline
with saved data preserves the stale local source. Cancellation, process
termination, a busy receipt lock, or an OS budget that prevents callback
completion produces no receipt and therefore remains unknown/waiting.

tvOS app digests include the closed Full Detail, Hide Account Names, or
Percentages Only presentation mode without including account values. Top Shelf
digests use only document timestamps, closed state and mode values, a coarse
freshness bucket, ordered provider/status/capacity categories, and whether the
extension returned content. They never hash card titles, detail strings, paths,
or raw errors.

## Session Gate

Receipt collection is dormant unless an explicit local session is active. A
session binds collection to one embedded manifest ID, an allowlist of surfaces,
and bounded collection policy:

- maximum session duration: six hours
- maximum write interval override: five minutes
- maximum receipt retention: seven days
- maximum per-session queue: 512 receipts
- hard local safety cap: 4,096 current-schema receipts

Normal defaults are a 30-minute session, a 30-second equivalent-state throttle,
a 24-hour receipt TTL, and 128 receipts. Equivalent repeated states are
rate-limited, while a state transition can write immediately.

Open a session for the canonical installed Mac build with:

```sh
scripts/context-panel-runtime-session.py start
```

To target every surface embedded in the installed manifest, use:

```sh
scripts/context-panel-runtime-session.py start --all-surfaces
```

The helper reads the embedded manifest from
`/Applications/Context Panel.app`, enables the three macOS surfaces, and writes
the session to the canonical app-group container. It does not install, launch,
replace, sign, or modify the app bundle.

Publish or clear the current session, upload pending Mac receipts, and extract
current-session receipts through the canonical signed refresh agent with:

```sh
scripts/context-panel-runtime-session.py sync
```

The helper itself never receives CloudKit credentials or entitlements. It asks
the installed signed refresh agent to use its existing Production CloudKit and
App Group authority, validates the agent's closed result contract, and reports a
degraded result without printing raw CloudKit errors.

Companion, Watch, tvOS, widget, complication, and Top Shelf writers require the
signed companion App Group and fail closed when that shared container is
unavailable. Entitled host apps load the active private CloudKit session and
mirror the same schema into the device-local companion container:

```text
group.com.shinycomputers.contextpanel/Context Panel/Validation
```

The companion app mirrors sessions for its app and widget surfaces. The Watch
app mirrors sessions for the Watch app and complication. The tvOS app mirrors
sessions for the app and Top Shelf. Each host rejects a session whose manifest
does not match its loaded build or whose enabled surfaces do not intersect the
local pair. A missing remote session clears the active local session only after
a successful CloudKit read; transient failures preserve the still-valid local
session until expiration.

After publishing a session, open each companion host once before expecting its
extension receipt. Open the Watch app before the complication and the tvOS app
before Top Shelf; the existing post-install Watch restart rule still applies.
Receipt silence before host delivery remains unknown/waiting rather than a
failed extension execution.

Inspect the current session and structurally valid observed surface count with:

```sh
scripts/context-panel-runtime-session.py status
```

Export the validated, de-duplicated local and CloudKit inbox as a redacted JSON
bundle with:

```sh
scripts/context-panel-runtime-session.py export --output runtime-receipts.json
```

The coordinator de-duplicates on the signed receipt payload, not on relay
envelope metadata. When the same receipt moves from the local queue to CloudKit,
the CloudKit source and server-received timestamp replace the local transport
metadata without invalidating proof. The same receipt ID paired with different
intrinsic runtime evidence remains a fail-closed conflict.

The durable coordinator consumes these contracts through a narrow adapter. Give
the coordinator the sealed expected-build manifests produced by the signed
archive flow, then run the explicit relay/reconciliation command:

```sh
scripts/context-panel-validation.py start-session \
  --version <marketing-version> \
  --build-number <coordinated-build-number> \
  --expected-build-manifest <ExpectedBuildManifest-platform.json>

scripts/context-panel-validation.py sync-runtime-evidence \
  --version <marketing-version> \
  --build-number <coordinated-build-number>
```

`sync-runtime-evidence` invokes the existing signed-host `sync`, validated
`status`, and exact-session `export` sequence. Ordinary coordinator `status`
uses only runtime-session `status` and `export`, so a read-only status check does
not perform CloudKit relay work. The adapter has no CloudKit client and never
reads raw receipt queues.

For proof, every actual identity field must match the sealed archive evidence:
version/build, source manifest and contract, surface fingerprints, bundle and
artifact, and the UUID of the loaded executable slice. A loaded UUID may be one
member of a multi-architecture archive's UUID set. Matching app receipts do not
stand in for widget, complication, or Top Shelf receipts from their own process
boundaries.

The coordinator persists only an additive schema-v1 summary sidecar keyed by
its session ID. It retains expected public build identity, receipt IDs and
ordering fields, exact-match digests, closed outcomes, and diagnostic codes. It
does not store raw receipt/export documents, signed-host messages, private
paths, device identifiers, account data, credentials, provider responses, or
App Store Connect IDs. The original coordinator lifecycle document remains
schema v1, and the sidecar is removed with its parent session retention.
Operator workflow state is separate again: grouped actions, bounded wait
timestamps, notification decisions, and expiring deferrals live in the additive
`Coordinator/Operator Flow` sidecar. They never change receipt proof, ordering,
session identity, or silence/diagnostic classification. See
[Signed Validation Operator Flow](signed-validation-operator-flow.md).

Within one process, `processSequence` is authoritative even when offline upload
changes server arrival order. Across processes/devices, the export uses the
CloudKit server receipt time and retains the device-observed timestamp without
claiming cross-device causality.

Close collection without deleting queued receipts with:

```sh
scripts/context-panel-runtime-session.py stop
scripts/context-panel-runtime-session.py sync
```

The second command writes a compare-and-swap remote tombstone for the closed
session and performs one final upload/extraction pass using the retained session
identity.

Use `--manifest`, `--root`, and explicit `--surface` arguments only for isolated
fixtures or when a coordinator supplies another exact signed-build
manifest. Do not use a source manifest to claim execution by an installed build.

## Local Storage

The canonical macOS session and queue live under:

```text
~/Library/Group Containers/MM5YXC7T6E.group.com.shinycomputers.contextpanel/Context Panel/Validation
```

Each receipt is an atomic standalone JSON file with a deterministic ID that is
recomputed when the queue is read. Writers take a nonblocking
cross-process lock only while checking the equivalent-state throttle, writing,
and pruning. A busy extension drops the attempt rather than blocking WidgetKit.
The next eligible execution may write another receipt.

Unknown future receipt schemas are ignored rather than deleted. Known current
receipts carry their own retention deadline. Queue-count pruning applies only to
the active session, so a later short session cannot delete still-valid evidence
awaiting relay from an earlier session. A separate hard safety cap removes the
oldest current-schema receipts only if all active session queues collectively
exceed 4,096 records. Stopping a session otherwise leaves receipts available
until their original deadline and preserves process ordering.

Every valid session is also stored in the bounded `Runtime Sessions` journal.
The operator refuses to start a second active session and refuses a new session
when 128 unexpired session identities are already retained, rather than silently
discarding evidence. Use `status --session-id <uuid>` or
`export --session-id <uuid>` to inspect an earlier retained session after a later
session begins.

Refresh receipts use the exact `StoredUsageSnapshot` captured by the refresh
runner while making its decision. They do not reload the mutable snapshot after
the refresh lock has been released. Equivalent-state throttling includes the
presentation digest, so a changed selected document can record immediately.

Companion app and widget writers share only their device-local companion App
Group queue. The app records after the exact loaded result, effective display
preferences, and visible appearance become model state. Widget receipts retain
the exact `CompanionSyncLoadResult` that produced the current entry, record only
that current entry once per callback, and distinguish iPhone, iPad, and visionOS
surface identities even though the iOS targets share bundle identifiers.

The Watch app and complication share only their Watch-local App Group queue.
The app records after the exact bounded load becomes visible. The complication
retains the exact cache or remote load that produced the current entry and
records only that entry, never synthetic future stale-transition entries.
Receipt throttling includes loaded executable identity so an old surviving
extension cannot suppress the first receipt after the required physical Watch
restart.

The tvOS app and Top Shelf extension share only their Apple-TV-local App Group
queue. The app records from its visible runway publication before asynchronous
Top Shelf publication. `topShelfContentDidChange()` remains an invalid proof of
extension execution; only the extension's `loadTopShelfContent()` callback can
write a `tvos.top-shelf` receipt. Missing documents remain degraded, renderer
errors can report failure, and OS cancellation remains receipt silence.

Entitled hosts acknowledge only receipt IDs that CloudKit accepted or already
stored with an identical payload. A small atomic sidecar keeps acknowledged IDs
until their receipt retention deadline, records capped exponential retry and
CloudKit retry-after deadlines, and schedules session refresh, extraction, and
cleanup work. This lets an offline failure retry in order without repeatedly
uploading the oldest batch. Retained-session extraction advances through a
persisted round-robin cursor while always including the active session.
Downloaded CloudKit envelopes are written to a separate
`Remote Runtime Receipts` inbox and are never read by the upload path. Local copies are removed
after their original receipt deadline. Remote copies become eligible at the same
deadline and are deleted in bounded batches by the next successful macOS host
cleanup.

The singleton remote session document uses CloudKit change-tag compare-and-swap
updates. Closing writes an `active`/`cleared` tombstone state instead of deleting
the record, so an older publish or clear cannot overwrite a newer session. The
receiver applies the server `stateUpdatedAt` revision and its local mirror update
under one App Group lock; an unversioned missing record does not erase a valid
local mirror.

## Evidence Limits

A receipt proves that the named exact-build process reached the recorded code
path and selected the sanitized state represented by the digest. It does not
prove:

- that WidgetKit composited or displayed the timeline entry
- that the widget remained placed
- that a human approved app-owned rendering
- that another embedded extension shares the app's build identity
- that a reload request caused execution

Placement and shared-view evidence therefore remain separate ledger classes.
Receipt silence remains unknown; it is not automatically a failure.

## Validation

Focused checks are:

```sh
swift test --filter \
  'ContextPanelCoreTests.runtime|ContextPanelCoreTests.snapshotRefreshEvidence'
uv run python -m unittest \
  Tests.ScriptsTests.test_runtime_receipts \
  Tests.ScriptsTests.test_runtime_session
scripts/validate-cloudkit-companion-schema.sh
```

The Swift tests cover manifest and loaded-executable binding, redaction,
deterministic digesting, widget preferences, companion platform/source mapping,
stable no-document companion states, effective visionOS appearance, Watch
deadline provenance, exact complication families, tvOS local-cache provenance,
Top Shelf privacy/freshness state, exact refresh evidence, session expiration,
loaded-executable-aware throttling, process ordering, tamper rejection,
host-only relay, de-duplication, retry acknowledgement, remote inbox isolation,
and per-session retention. Script tests verify every shipping process hook,
required App Group routing, strict local/remote receipt validation, and the
operator session/sync/export lifecycle. The checked-in CloudKit gate covers the
companion snapshot plus the dedicated runtime session and receipt record types.
Its `--live --environment production` form is read-only and must pass before a
signed release relies on the relay.
Generic iOS, visionOS, watchOS, and tvOS Xcode builds remain required because
SwiftPM tests run only host-compatible modules.
