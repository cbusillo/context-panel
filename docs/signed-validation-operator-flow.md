# Signed Validation Operator Flow

The signed validation coordinator turns machine evidence into one calm operator
queue. It does not manage devices, deliver notifications, approve visual output,
or change release gates. Those boundaries keep the queue read-only with respect
to signed runtimes, App Store Connect, CloudKit schema, user data, and existing
widget, complication, and Top Shelf placements.

## Queue Policy

`status` groups ready actions by the public device class: Mac, iPhone, iPad,
Vision Pro, Apple Watch, Apple TV, or Coordinator. Each action has a stable ID,
plain instruction, honest time estimate, bounded recovery sequence, and optional
notification decision.

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
`readyForHumanReview` is reserved for the dedicated approval flow. Exact runtime
proof alone remains a successful coordinator result and does not create an
unfinishable visual-review action in this slice. Signed validation galleries
provide separately labeled shared-view evidence; they do not become coordinator
approval records until the visual approval ledger supplies an explicit review
requirement and matching decision.

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
Visual approval remains `not-evaluated-by-coordinator` until the dedicated
approval flow supplies it. Carry-forward remains `not-evaluated` until the
release-gate integration owns that decision.

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
