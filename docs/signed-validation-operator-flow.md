# Signed Validation Operator Flow

The signed validation coordinator turns machine evidence into one calm operator
queue. It does not manage devices, deliver notifications, make visual judgments,
or change release gates. It records explicit human approve/reject decisions but
never makes the visual judgment itself. Those boundaries keep the queue
read-only with respect
to signed runtimes, App Store Connect, CloudKit schema, user data, and existing
widget, complication, and Top Shelf placements.

## Automation Boundary

`advance-automation` is the sole state-changing coordinator automation command
in this slice. It can run only for an active coordinator session. It first makes
one bounded attempt to launch the canonical Mac app when a requested macOS
surface has the exact current Production identity and the app is verified not
running, then performs the existing signed-host runtime-receipt
relay/reconciliation sequence. The launch uses `/usr/bin/open -g` only; it does
not install, reset, activate a URL, change placements, or touch a companion
device. When shared-view requirements exist, the command then attempts the
existing bounded simulator capture executor after receipt synchronization. The
executor can route Watch gallery cells directly on a throwaway Watch simulator
with the fixed `simctl launch --terminate-running-process` fixture/family
arguments; it does not mutate Watch appearance, depend on a paired iPhone
simulator, or make an app-written attestation. The private comparison, manifest,
requirements, capture config, artifact root, and receipt output are supplied
only to that invocation and are never persisted in coordinator state. Missing
inputs are recorded as an unsupported terminal attempt so the human review can
proceed honestly rather than looping. That unsupported fallback is visible in
the automation report but does not degrade an otherwise healthy
`advance-automation` exit code.

A missing or incompatible Watch simulator topology, install, or container
identity is fail-closed shared-view capture evidence, not a signal to create a
pair, alter the signed build, or use physical-device navigation. Watch capture
continues to be structurally incapable of satisfying `actual-runtime` or
`os-composited-placement`; placed-complication review and the exact-build Watch
restart rule remain separate physical evidence.

Private capture configs created before Watch capture support must add an
explicit `watchos` profile before processing a plan with Watch shared-view
requirements. Without it, those requirements report `profile-not-configured`
and automation remains fail closed rather than silently treating Watch as an
unsupported host mechanism.

The command records a schema-v1 public automation sidecar bound by digests to
the coordinator session, target, and requested surfaces. It persists only fixed
result/reason vocabularies, timestamps, counts, booleans, and SHA-256 digests.
It never stores device identifiers, account data, raw tool output, arguments,
paths, or runtime receipt payloads. Sidecars use the coordinator lock, atomic
mode-`0600` writes, and the same retention cleanup as their parent session.

`status` and `final-report` include the bounded public automation report but do
not invoke this command, launch the app, or trigger the signed-host relay. A
pending supported Mac launch is shown as a Coordinator follow-up before the
manual Mac-open action. After a current-window launch attempt fails or is
unsupported, the original human action is shown unchanged; a verified launch
removes it through ordinary status recollection. Launch attempts use the same
five-minute cooldown and stop after two attempts for one unchanged Mac state,
preventing relaunch loops. Already-proven runtime
evidence or the explicit cooldown makes repeated advancement idempotent. After
the cooldown, an active receipt window may sync again so newly relayed receipts
can be collected; an unsupported adapter is also retried rather than latched
permanently. A changed or expired receipt window may advance immediately.
The schema-v1 sidecar supports three closed kinds: `runtime.receipt.sync`,
`macos.app.launch`, and `shared-view.capture`. Shared-view review actions are
replaced by one Coordinator capture follow-up until a terminal attempt exists
for the current manifest and requirement set. A successful capture never makes
the visual judgment; it only ensures fresh artifacts exist before the human
review. The total budget is 96
attempts, partitioned as 64 receipt, 16 launch, and 16 capture attempts. No
launch command path, arguments, output, or process details are persisted. Closed
and superseded sessions never advance automation.

## Queue Policy

`status` preserves the historical per-device batch structure in
`visualApprovals.reviewBatches`: each batch retains its action ID, device,
requirement IDs, and evidence class for replay fidelity. New shared-view
batches also carry a deterministic optional `consolidationID`, derived from the
current manifest and their complete ready requirement set. The Coordinator folds
only batches with the same valid identifier into one shared-view review action
with sorted unioned surfaces and public device classes. The folded action has a
strict 60-minute maximum estimate; malformed identifiers, mixed evidence
classes, inconsistent membership, or an over-budget group fail closed.
Historical reports without `consolidationID` keep their original per-device
queue unchanged.

Placement batches never carry `consolidationID`, remain per-device and
runtime-gated, and cannot be folded. Mac, iPhone, iPad, Vision Pro, Apple Watch,
Apple TV, and Coordinator remain the only public
device labels. Each action has a stable class-specific ID, plain instruction,
honest time estimate, bounded recovery sequence, and optional notification
decision. A `.part-N` suffix appears only when a device-and-class batch exceeds
the bounded review size.

Every queued action also carries a fail-closed machine-readable contract:

- `surfaces`: the exact non-empty subset of requested surfaces affected by the
  action
- `reasonCode`: a closed-vocabulary explanation of why the action is requested
- `actionKind`: a closed-vocabulary classification of the work
- `durationMinutes`: an integer from 1 through 60
- `evidenceClass`: exactly one of `shared-view` or
  `os-composited-placement` for a visual-review batch
- `requiresRuntime` and `runtimeSurfaces`: class-consistent runtime scope;
  shared-view batches use `false` and `[]`, while placement batches use `true`
  and the exact batch surfaces
- `simulationInsufficiency`: a closed-vocabulary code plus a public explanation
  of why simulator or machine evidence cannot complete the action

The coordinator rejects missing or unknown contract fields before writing the
operator-flow sidecar or notification decisions. Every action is bounded to 60
minutes, large visual-review sets are split into bounded batches, and each device
group plus the complete queue reports its exact aggregate `durationMinutes`.
The final-report builder and release-evidence gate revalidate the same contract
and aggregates, so stale or hand-edited action data cannot bypass the planning
budget.

Status output omits device classes outside the requested surface scope. An
unchanged or unrelated device is therefore neither a blocker nor an implied
next action.

Passive machine waits stay quiet:

- Apple processing or TestFlight assignment
- target installation propagation
- active runtime receipt propagation
- CloudKit relay delay inside its bounded receipt window
- newly observed lock, sleep, or reachability loss

Locked or sleeping devices remain passive for 15 minutes. If the state is still
present, the queue requests one unlock or wake and explicitly says that no
extended awake period is required. Reachability failures remain passive for 30
minutes before the queue asks for a decision. These timers are persisted by
public device class only; no device identifier or name is stored.

CoreDevice tunnel state is advisory. For a booted physical device, the
coordinator attempts the bounded read-only installed-app query even when the
listed developer tunnel is disconnected, because local-network queries can
still succeed. A failed query remains a reachability wait. After every requested
surface has an exact-build runtime receipt and required restart evidence is
recorded, a later device reachability loss does not keep the completed slice
open.

The current Watch rule remains authoritative. Once the exact Watch build is
observable, the queue requests one restart with placements intact. The existing
`record-watch-restart` command records only that operator attestation. A Watch
app receipt or restart attestation never proves complication execution; the
complication still requires its own exact-build receipt.

Stale-extension recovery is progressive and non-destructive:

1. Preserve the installed signed app, local data, and existing placement.
2. Open the signed host app once and allow its normal extension refresh path.
3. Start a fresh bounded receipt window only when the prior window expired.
4. Escalate manifest, session, schema, or relay diagnostics without treating
   receipt silence as a product failure.

## Notification Decisions

The coordinator computes notification decisions but does not deliver them. The
only permitted decision kinds are:

- `readyForHumanReview`
- `restartRequired`
- `manualUnlockRequired`
- `blockedDecisionRequired`

Each decision has a deterministic ID bound to the coordinator session, action,
and decision kind. Repeated status reads and process interruption therefore do
not create duplicate decisions. Active deferrals suppress the current decision;
they do not alter evidence or mark a surface complete.
`readyForHumanReview` is emitted only for explicit visual requirements whose
machine prerequisites are ready. Shared-view requirements bind to exact render
and fixture/gallery contract identity and remain ready even when an unrelated
placement requirement on the same device is waiting. Placement requirements
remain silent until every exact `runtimeSurface` in their batch is independently
`proven`; the coordinator does not use an overall runtime state or proof for a
different surface as a substitute. Each batch contains one evidence class and
names only the exact requirement IDs and surfaces it covers; it never expands to
every surface on the device.

## Visual Review Ledger

Start the coordinator with the current surface comparison, sealed expected-build
manifests, and an explicit review-requirements file:

```sh
scripts/context-panel-validation.py start-session \
  --version <marketing-version> \
  --build-number <coordinated-build-number> \
  --surface-comparison <comparison.json> \
  --visual-review-requirements <visual-review-requirements.json> \
  --expected-build-manifest <ExpectedBuildManifest-platform.json>
```

The comparison is authoritative only for `requiredSurfaces`. The coordinator
does not consume its `carryForward` entries; release-train carry-forward remains
outside this slice. Runtime surfaces are derived from
`requiredSurfaces.actual-runtime`. Every shared-view and
`os-composited-placement` surface must have at least one explicit context in the
requirements file, and no context may name a surface outside the comparison.

For shared-view contexts, plan the requirements before starting a coordinator
session. The planner accepts only a current schema-v5 comparison and binds the
output's `currentManifestID` to that comparison:

```sh
scripts/context-panel-validation.py plan-shared-view-evidence \
  --surface-comparison <comparison.json> \
  [--base-requirements <placement-requirements.json>] \
  --output <visual-review-requirements.json>
```

It reads the canonical schema-v1 matrix at
`Config/ContextPanelSharedViewMatrix.json` unless `--matrix` or
`--surface-policy` is supplied. The matrix covers every shared-view-capable
surface with bounded, canonical cells and each host gallery's real selectors.
An axis set to `not-applicable` is intentionally absent from that host gallery;
the capture step must not try to drive it. Pixel policy is `advisory-only`. The
command is read-only with respect to coordinator state: it does not start a
session, inspect a runtime, launch a simulator, or capture private artifacts.
Mixed shared-view and placement comparisons are accepted. Pass an explicit
placement requirements file with `--base-requirements` to produce one combined
plan: non-shared requirements are preserved verbatim, canonical matrix-derived
shared-view requirements are added, and conflicting existing shared entries
fail closed. The base file is never rewritten implicitly. Omitting the base on
a mixed comparison emits a warning; the resulting shared-only file can drive
capture, but `start-session` still rejects it for missing placement coverage.

For supported simulator companion galleries, run the private executor after
planning. It requires the same schema-v5 comparison, the canonical current
source manifest, and the exact planned requirements:

```sh
scripts/context-panel-validation.py capture-shared-view-evidence \
  --surface-comparison <comparison.json> \
  --current-manifest <current-surface-manifest.json> \
  --requirements <visual-review-requirements.json> \
  --capture-config <private-capture-config.json> \
  --artifact-root <absolute-private-artifact-root> \
  --output <absolute-shared-view-capture-receipt.json>
```

The requirements input may be the combined coordinator plan. The executor
projects only its canonical shared-view subset, preserves those exact
requirement IDs, and binds the receipt digest to that projection. Placement
entries remain in the authoritative file but are never captured or claimed as
shared-view evidence.

The executor uses only throwaway iOS, iPadOS, and visionOS simulators, installs
a private immutable app snapshot, verifies the installed container, and emits a
sanitized build-bound receipt. It writes no coordinator, runtime, approval, or
visual-review state. Unsupported hosts and missing profiles remain explicit;
capture or cleanup uncertainty never becomes success.

The requirements file uses schema v1 and stores bounded public context:

- stable requirement ID and evidence class
- surface, appearance, and accessibility context
- fixture/gallery contract digest and presentation for shared views
- host OS, presentation family, and placement host for placed surfaces

The coordinator expands each requirement with the sealed exact-build manifest
ID, contract fingerprint, expected-build ID, render fingerprint, and placement
fingerprint where applicable. Shared-view records can never claim placement
proof. Placement records fail closed unless the host OS matches and a current
exact-build runtime receipt exists for the same surface.

Record the ready requirement shown by `status --json`:

```sh
scripts/context-panel-validation.py record-visual-review \
  --version <marketing-version> \
  --build-number <coordinated-build-number> \
  --requirement-id <requirement-id> \
  --decision <approved|rejected> \
  --host-os <required-host-os> \
  --artifact <optional-private-artifact>
```

Omit `--host-os` for shared-view decisions. The optional artifact is hashed in
place; its path and contents are never persisted. Repeating an identical
decision is idempotent. A changed decision appends a new sequence entry with an
explicit `supersedesDecisionID`, preserving the earlier record across process
interruption and resume.

Export bounded public metadata with:

```sh
scripts/context-panel-validation.py export-visual-reviews \
  --version <marketing-version> \
  --build-number <coordinated-build-number> \
  --json
```

The schema-v1 ledger lives under
`Context Panel/Validation/Coordinator/Visual Approvals`, is bound to the
coordinator session and exact target, uses atomic mode-`0600` writes, and is
pruned with parent-session retention. It stores hashes and public platform
context only—never artifact paths, device identifiers, reviewer identity,
account data, or credentials.

## Deferrals

Run `status --json` first and use the stable action ID shown in
`operatorFlow.groups`:

```sh
scripts/context-panel-validation.py defer-action \
  --version <marketing-version> \
  --build-number <coordinated-build-number> \
  --action-id <action-id> \
  --owner release-operator \
  --reason operator-unavailable \
  --residual-risk review-pending \
  --duration-hours 4
```

Owners are public-safe labels rather than names, email addresses, handles, or
device identifiers. Reasons and residual risks are allowlisted. A deferral is
bounded to at most seven days, remains in the retained session history after it
expires, and never changes runtime proof, restart attestation, or evidence
counts. When every current action is deferred, status reports
`ready_for_you / deferred` as an unresolved operator requirement with exit `10`;
it never reports the
requirement complete or a shell-level success.

Clear an active deferral without deleting its residual-risk history:

```sh
scripts/context-panel-validation.py clear-deferral \
  --version <marketing-version> \
  --build-number <coordinated-build-number> \
  --action-id <action-id>
```

## Persistence

Operator state uses an additive schema-v1 sidecar under:

```text
Context Panel/Validation/Coordinator/Operator Flow/<coordinator-session-id>.json
```

The durable lifecycle document remains schema v1. The sidecar is bound to the
session ID, version/build, and requested surfaces; it cannot be reused across a
replacement or newer build. Writes share the coordinator lock, are atomic,
mode `0600`, and are pruned with the parent session retention.

Persisted fields are limited to public action IDs, public device classes,
bounded wait timestamps, allowlisted notification decisions, and deferral
owner/reason/expiry/residual-risk codes. The sidecar contains no device
identifiers, account data, credentials, private paths, App Store Connect object
IDs, raw provider responses, raw CloudKit messages, or raw runtime receipts.

## Final Report

Generate a GitHub-ready Markdown report:

```sh
scripts/context-panel-validation.py final-report \
  --version <marketing-version> \
  --build-number <coordinated-build-number>
```

Pass `--json` for the stable machine-readable contract. The report names the
exact target, session lifecycle, required and obtained evidence classes,
runtime surface states, grouped actions, notification decisions, blockers,
deferrals, residual risk, and the current carry-forward boundary. It omits the
coordinator session UUID as well as all private identifiers and raw evidence.
`totalDurationMinutes` is a derived aggregate equal to the sum of the reported
group durations. Historical lineage reports generated before scoped action
contracts introduced that field may omit it during release-gate reconstruction;
current reports remain strict, and retained lineage payloads are never mutated
or backfilled.
Visual approval reports `pending`, `waiting`, `approved`, or `rejected` from the
ledger. A rejection blocks the coordinator result, and missing or stale
placement runtime evidence cannot report green. Carry-forward remains
`not-evaluated` until the release-gate integration owns that decision.

Status and final-report exit codes remain:

- `0`: machine waiting or complete for the available coordinator slice
- `10`: one or more operator actions are ready or actively deferred
- `20`: a real blocker or superseded target
- `30`: evidence is unknown or diagnostic
- `1`: internal coordinator error

## Shadow Validation

Before replacing any current runbook safeguard, run at least two signed,
cross-platform shadow sessions and compare every coordinator result with the
current runbook. Across those sessions cover:

- iPhone or iPad lock and unlock
- Vision Pro sleep or tunnel loss
- Apple TV sleep or reachability loss
- Watch update, required restart, and complication receipt collection
- host-current/extension-stale behavior
- bounded CloudKit delay and diagnostic escalation
- interruption followed by status/resume without repeated proof or mixed builds

Shadow evidence is recorded in the owning GitHub issue or private release
artifact, not in the public coordinator sidecar. Use only public platform names,
the exact version/build, scenario outcomes, and redacted timestamps. The current
runbook remains the comparison oracle until the later release-policy work
explicitly changes that rule.
