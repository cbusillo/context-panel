# Publication-time CloudKit check

Chris chose [Q43 option B](https://github.com/cbusillo/context-panel/issues/790#issuecomment-6050480231):
keep the management token on the Mac and send CI only a checked result.
This file owns relay operation and replacement. The
[Production schema gate](release.md#cloudkit-production-schema-gate) owns the
schema contract, existing credential setup and direct local-release route.

## How it works

Leave `cloudkit_schema_receipt_base64` empty when dispatching Ship or a standalone
publication workflow. Each selected channel
builds first, then the shared `cloudkit-publication-check` action posts a one-day
request artifact and waits up to twenty minutes for the Mac. GitHub publication
requests after notarization; Mac/companion uploads archive first and upload the
same verified archive afterward. TestFlight and Review request before their
live commands. Export-only, artifact-only, dry-run and cancel-only paths do not
request a check.

The Mac's operator process reads active protected-main release requests through
the existing automation GitHub helper. It requires completed source trust and
automatic release-intent jobs, the current run attempt, and a commit still in protected
main. It reads the two schema contracts and compares three gate scripts from
that commit in its local Git object database. It executes its own reviewed
validator, never downloaded code.
At most one live Production export per request must satisfy the existing schema validator;
an export error or mismatch sends no success result.

A successful check seals a receipt with the existing authentication key and a
digest binding repository, source commit, run ID, attempt, channel and random
nonce. The Mac dispatches the secretless `CloudKit Schema Result` workflow,
which stores that receipt as a result artifact. The mailbox is untrusted: that
workflow does not authenticate the result. The waiting release authenticates its
seal, exact contract and request before continuing. Its live entrypoint verifies
again. Those verifications are not additional live schema exports.

The receipt's existing six-hour lifetime remains. It starts after intent
recording and build, rather than at dispatch. The twenty-minute wait bounds how
long a publication can wait for the new check; a new dispatch makes a new request.
Expired or tampered results, other runs/attempts/channels/contracts and missing
results cannot authorize publication. Cancellation during a check stops its
result relay. A race after that readback remains harmless because a canceled
publication cannot consume it and a rerun uses another attempt and nonce.

GitHub uses its existing Actions authentication and receipt key. The Mac uses the
existing automation App helper for Actions reads and result dispatch. No new
CloudKit credential, CI secret, runner registration, network listener or token
store is required. The existing automation App must already have scoped Actions
read/write permission; confirm that through the maintained GitHub capability
audit before activation. A missing grant is a stop for Chris, not an agent
workaround. The result workflow has no secret environment.
Requests/results contain source and run metadata, contract digests, timestamps
and seals, never token/key values, account data or live schema exports.

## Scheduled checker on Chris's Mac

Chris approved running the checker on its own
([#897](https://github.com/cbusillo/context-panel/issues/897)). A user
LaunchAgent on Chris-Studio runs one pass every 60 seconds and at login, so a
release needs no one to start the checker. It uses the existing receipt key in
Keychain and cktool's existing management token. Do not create, rotate, move or
inspect credentials. If either credential is unavailable, stop for Chris; do
not create a replacement.

| Part | Where |
| --- | --- |
| LaunchAgent | `~/Library/LaunchAgents/com.shinycomputers.contextpanel.cloudkit-operator.plist` |
| Operator checkout | `~/.local/share/context-panel-cloudkit-operator`, a standalone clone of the public repository over HTTPS on branch `main` |
| Command | `/bin/bash <checkout>/scripts/cloudkit-schema-operator.sh --follow-main --log <log> ~/Developer/codex-skills/skills/github/scripts/gh-with-env-token` |
| Log | `~/Library/Logs/context-panel-cloudkit-operator.log`, one previous file kept as `.log.1` after 1 MiB |
| Served state | `<checkout>/.build/cloudkit-relay-served.json` |

The checkout lives on the internal disk. It is not the primary checkout or a
task worktree, so worktree retirement and task-evidence cleanup never touch
it, and launchd can run scripts from it. Nobody edits it.

`--follow-main` fetches protected `main` and fast-forwards the checkout before
each pass, then runs the pass with the wrapper that `main` now holds. It refuses
a dirty checkout, a checkout off `main` and local commits not on `main`. The
checker refuses unless its local relay, validator and receipt implementation
match the release commit. So a release dispatched before a gate-code change
cannot be checked; redispatch it from current protected main. Unrelated product
commits do not matter. `--log` appends each pass's output and a line ending
`operator pass exit N`. An idle pass prints only that line. The wrapper also
refuses Actions and non-Mac hosts. Keep the Mac awake, logged in and online.

Install or reinstall: clone `https://github.com/cbusillo/context-panel.git`
into the checkout path, write the plist with `Label`, the command above as
`ProgramArguments` (absolute paths), `StartInterval` 60, `RunAtLoad` true, the
log as `StandardErrorPath`, and `PATH` covering `uv`, `git` and `gh`. Then run
`launchctl bootstrap gui/$(id -u) <plist>`.

Check it with `launchctl print gui/$(id -u)/com.shinycomputers.contextpanel.cloudkit-operator`
and `tail` of the log.

Pause it with `launchctl bootout gui/$(id -u)/com.shinycomputers.contextpanel.cloudkit-operator`;
bootstrap the plist again to resume. Remove it by booting it out and deleting
the plist, the checkout and the log. A single pass by hand is the same command
without `--log`.

Fake tests qualify source behavior. They do not prove Keychain access, live
schema correctness or hosted artifact transport; the next authorized Ship does.
Check its request/result artifacts, matching commit/attempt/channel, and
publication's successful receipt verification.

The checker takes an OS file lock for this operator checkout. Overlapping passes
return without exporting. Requests are recorded by digest in the ignored,
nonsecret `.build/cloudkit-relay-served.json` immediately before the live export, with outcomes
`checking`, `dispatched` or `failed`. This prevents duplicate exports even after
a crash or an ambiguous response dispatch. One refused request does not stop
other channels or runs from receiving their checks. State is retained for one
day. Use only the scheduled operator checkout.

A failed or interrupted export/dispatch remains blocked and is not exported again.
Retryable GitHub reads that fail before any export leave the request unrecorded;
a later pass can recover without repeating a live check.
Missing Git objects or outdated local gate code also leave it unrecorded;
the next pass fetches again, and a release from older gate code needs a redispatch.
Diagnose it, then use a new dispatch or authorized rerun, which generates a new
nonce. Successful trust/intent jobs from an earlier attempt of the *same run*
can support a partial rerun; a newer failed/pending guard overrides them. The
check reads the [complete job history](https://docs.github.com/en/rest/actions/workflow-jobs)
and refuses incomplete coverage. If a response workflow alone fails after a
confirmed dispatch, retry that response workflow through its normal route;
do not erase state or re-seal old evidence. Hosted waits tolerate transient
read failures and ignore unauthenticated results until their deadline; canceled
runs and GitHub API authentication refusals still stop.
The result dispatch itself is never blindly retried: a timeout may mean GitHub
accepted it. Check the result workflow first. If no confirmed response can be
recovered, a new publication attempt makes a new request and check.

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
- **Pausing:** boot out the scheduled checker (above). Hosted publication stays blocked until
  fresh evidence arrives or its wait expires. Preserve placed widgets and signed
  runtime; this relay has no app/device responsibilities.

Artifacts expire after one day. Temporary schema exports and receipt files on the
Mac are removed before the result dispatch. Do not retain exported live schemas in
public artifacts or print subprocess authentication diagnostics.

## Changing the decision later

| Choice | Seam to change | Consequence |
| --- | --- | --- |
| B (current default) | Empty receipt input; shared action plus operator wrapper | Mac must be available only near publication; no new credential in CI. |
| C (existing compatibility path) | Supply `cloudkit_schema_receipt_base64` using the documented operator gate | Shared action verifies it directly; no relay request. Build waiting again consumes its lifetime. Remove the scheduled checker when all runs use this path. |
| A (new Director access decision) | Replace request/wait in the shared action with a hosted live export and receipt issuance | CI receives the management credential's broader schema authority. Chris must authorize and place it. Do not widen guarded dependencies or bypass the publisher verifier. |

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
