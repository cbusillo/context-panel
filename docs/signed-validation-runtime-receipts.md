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

Watch, complication, tvOS, Top Shelf, validation-session delivery to companion
devices, host relay, and private CloudKit receipt transport remain follow-up
work under issue #520.

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

The helper reads the embedded manifest from
`/Applications/Context Panel.app`, enables the three macOS surfaces, and writes
the session to the canonical app-group container. It does not install, launch,
replace, sign, or modify the app bundle.

Companion app and widget writers require the signed companion App Group and fail
closed when that shared container is unavailable. They read the same session
schema from the device-local companion container:

```text
group.com.shinycomputers.contextpanel/Context Panel/Validation
```

The current operator helper does not deliver a session to a physical companion
device and does not extract its receipts. Those writers therefore remain dormant
until a later validation-session delivery/private relay slice supplies the exact
manifest-bound session on that device. Do not copy a Mac session file manually
and treat the resulting receipt as coordinated signed-device evidence.

Inspect the current session and structurally valid observed surface count with:

```sh
scripts/context-panel-runtime-session.py status
```

Close collection without deleting queued receipts with:

```sh
scripts/context-panel-runtime-session.py stop
```

Use `--manifest`, `--root`, and explicit `--surface` arguments only for isolated
fixtures or when a later coordinator supplies another exact signed-build
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
```

The Swift tests cover manifest and loaded-executable binding, redaction,
deterministic digesting, widget preferences, companion platform/source mapping,
stable no-document companion states, effective visionOS appearance, exact
refresh evidence, session expiration, digest-aware throttling, process ordering,
tamper rejection, and per-session retention. Script tests verify the macOS and
companion process hooks, required App Group routing, strict receipt validation,
and the operator session lifecycle. Generic iOS and visionOS Xcode builds remain
required because SwiftPM tests run only the host-platform Core target.
