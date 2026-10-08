# Publication-time CloudKit check

Chris chose [Q43 option B](https://github.com/cbusillo/context-panel/issues/790#issuecomment-6050480231):
keep the management token on the Mac and send CI only a checked result.
This file owns relay operation and replacement. The
[Production schema gate](release.md#cloudkit-production-schema-gate) owns the
schema contract, existing credential setup and direct local-release route.

## How it works

Leave `cloudkit_schema_receipt_base64` empty when dispatching Ship or a standalone
publication workflow. Approval can wait as long as needed. Each selected channel
builds first, then the shared `cloudkit-publication-check` action posts a one-day
request artifact and waits up to twenty minutes for the Mac. GitHub publication
requests after notarization; Mac/companion uploads archive first and upload the
same verified archive afterward. TestFlight and Review request before their
live commands. Export-only, artifact-only, dry-run and cancel-only paths do not
request a check.

The Mac's operator process reads active protected-main release requests through
the existing automation GitHub helper. It requires completed source trust and
owner approval jobs, the current run attempt, and a commit still in protected
main. It reads only the two schema contracts from that commit in its local Git
object database. It executes its own reviewed validator, never downloaded code.
At most one live Production export per request must satisfy the existing schema validator;
an export error or mismatch sends no success result.

A successful check seals a receipt with the existing authentication key and a
digest binding repository, source commit, run ID, attempt, channel and random
nonce. The Mac dispatches the secretless `CloudKit Schema Result` workflow,
which stores that receipt as a result artifact. The mailbox is untrusted: that
workflow does not authenticate the result. The waiting release authenticates its
seal, exact contract and request before continuing. Its live entrypoint verifies
again. Those verifications are not additional live schema exports.

The receipt's existing six-hour lifetime remains. It starts after approval and
build, rather than at dispatch. The twenty-minute wait bounds how long a
publication can wait for the new check; a new dispatch makes a new request.
Expired or tampered results, other runs/attempts/channels/contracts and missing
results cannot authorize publication. Cancellation during a check stops its
result relay. A race after that readback remains harmless because a canceled
publication cannot consume it and a rerun uses another attempt and nonce.

GitHub uses its existing Actions authentication and receipt key. The Mac uses the
existing automation App helper for Actions reads and result dispatch. No new
CloudKit credential, CI secret, runner registration, network listener, access
grant or token store is required. The result workflow has no secret environment.
Requests/results contain source and run metadata, contract digests, timestamps
and seals, never token/key values, account data or live schema exports.

## Activation on Chris's Mac

Activation is separate from the source PR. **Ask Chris before running the
operator wrapper**, which reads the existing receipt key from Keychain and lets
cktool use its existing management token. Do not create, rotate, move or inspect
credentials as preparation. Nothing in this PR starts a checker, installs a
service or dispatches a release.

After Chris authorizes activation:

1. Use a clean, reviewed operator checkout containing the landed relay. Fetch
   protected `origin/main` so the release source's Git objects are present;
   the wrapper refreshes those Git objects on every pass without changing
   checked-out files. No checkout of incoming request code is necessary. Keep this local validator
   current when gate code changes: the checker refuses unless its local relay,
   validator and receipt implementation match that release commit. If gate code
   has changed since a waiting release was dispatched, either use its matching
   reviewed operator checkout or redispatch from the updated protected-main
   source. Unrelated product commits need only the per-pass Git fetch.
2. Use the existing credential setup described in the schema gate. If either
   credential is unavailable, stop for Chris; do not create a replacement.
3. Run one pass from that checkout, passing the existing bot GitHub wrapper:

   ```sh
   scripts/cloudkit-schema-operator.sh /absolute/path/to/gh-with-env-token
   ```

4. While releases publish, repeat that command about once a minute through the
   operator's existing agent/scheduler. `serve-once` processes active requests
   then exits. The wrapper refuses Actions, non-Mac and dirty checkouts. Keep the
   Mac awake and online. Scheduling/login startup is an operator setup decision;
   the helper deliberately installs nothing.
5. Validate with a separately authorized release: check the request/result
   artifacts, matching commit/attempt/channel, and publication's successful
   receipt verification. Fake tests qualify source behavior; they do not prove
   Keychain access, live schema correctness or hosted artifact transport.

The checker takes an OS file lock for this operator checkout. Overlapping passes
return without exporting. Requests are recorded by digest in the ignored,
nonsecret `.build/cloudkit-relay-served.json` immediately before the live export, with outcomes
`checking`, `dispatched` or `failed`. This prevents duplicate exports even after
a crash or an ambiguous response dispatch. One refused request does not stop
other channels or runs from receiving their checks. State is retained for one
day. Use this one operator checkout for the scheduled checker.

A failed or interrupted export/dispatch remains blocked and is not exported again.
Retryable GitHub reads that fail before any export leave the request unrecorded;
a later pass can recover without repeating a live check.
Diagnose it, then use a new dispatch or authorized rerun, which generates a new
nonce. Successful trust/approval jobs from an earlier attempt of the *same run*
can support a partial rerun; a newer failed/pending guard overrides them. The
check reads the [complete job history](https://docs.github.com/en/rest/actions/workflow-jobs)
and refuses incomplete coverage. If a response workflow alone fails after a
confirmed dispatch, retry that response workflow through its normal route;
do not erase state or re-seal old evidence. Hosted waits tolerate transient
read failures and ignore unauthenticated results until their deadline; canceled
runs and authentication refusals still stop.

## Failure and recovery

- **No result within twenty minutes:** the release fails before publishing. Check
  Mac availability, operator-pass failure, Git object availability and the result
  workflow's queue. Keep every gate; do not extend an old receipt or re-seal old
  evidence. A fresh dispatch/rerun gets another request after its normal gates.
- **Export/schema failure:** run the existing validator under operator authority
  to diagnose. Fix the schema through its existing decision/release path. A
  mailbox result cannot override this failure.
- **GitHub/helper refusal or incomplete inventory:** stop that pass and preserve
  existing auth. Never fall back to Chris's personal GitHub identity. The checker
  uses bounded pagination and result-name filters from the
  [GitHub artifact API](https://docs.github.com/en/rest/actions/artifacts).
- **Result fails seal/contract/request/freshness checks:** publication stops;
  inspect that exact request and result, rather than substituting another run.
- **Pausing:** stop the operator passes. Hosted publication stays blocked until
  fresh evidence arrives or its wait expires. Preserve placed widgets and signed
  runtime; this relay has no app/device responsibilities.

Artifacts expire after one day. Temporary schema exports and receipt files on the
Mac are removed before the result dispatch. Do not retain exported live schemas in
public artifacts or print subprocess authentication diagnostics.

## Changing the decision later

| Choice | Seam to change | Consequence |
| --- | --- | --- |
| B (current default) | Empty receipt input; shared action plus operator wrapper | Mac must be available only near publication; no new credential in CI. |
| C (existing compatibility path) | Supply `cloudkit_schema_receipt_base64` using the documented operator gate | Shared action verifies it directly; no relay request. Approval/build waiting again consumes its lifetime. Stop scheduling operator passes when all runs use this path. |
| A (new Director access decision) | Replace request/wait in the shared action with a hosted live export and receipt issuance | CI receives the management credential's broader schema authority. Chris must authorize and place it. Do not widen approval dependencies or bypass the publisher verifier. |

All five workflow boundaries use the same composite action. The receipt
issue/verify API accepts optional `publicationRequestDigest`; unbound legacy receipts
remain supported for C and direct local commands. Bound results require their original request and cannot be supplied through C
or a direct command without it. Keep source/contract/seal and expiry checks in
every option. There is no receipt-validity override.

For A, remove the now-unused relay workflow, operator wrapper, transport helper
and behavioral tests when their consumers are gone. Do not duplicate the schema
validator or credential setup. For C, keeping the shared action's compatibility
branch makes switching back to B a dispatch-input choice rather than secret
migration. Test the chosen behavior with fake clocks/schema exports before any
separately authorized live acceptance.
