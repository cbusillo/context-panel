# Validation Authority and Operator Route

Start here before selecting a validation path. This page routes decisions to
owning sources; it does not define policy values, fixture contents, thresholds,
or active train status. Keep those in their existing sources.

## Sources of truth

Explicit user instructions define the requested outcome. Validation is
simulator-first: simulators and host rendering prove shared views, and signed
builds prove runtime and placement only where they changed. Every platform
ships together as one release ([definition of released](release.md#definition-of-released)).

| Question | Owning source |
| --- | --- |
| What must this exact candidate prove? | [Surface policy](../Config/ContextPanelSurfacePolicy.json), [release-evidence policy](../Config/ContextPanelReleaseEvidencePolicy.json), [matrix](../Config/ContextPanelSharedViewMatrix.json), and the complete source/build-manifest comparison |
| How does the implemented path operate? | [Release procedure](release.md), [coordinator](signed-validation-operator-flow.md), and [capture mechanisms](signed-validation-galleries.md) |

Code, tests, documentation, and historical artifacts show implemented behavior
and evidence. They do not independently redefine the agreed outcome. If these
sources disagree, reconcile the owning plan and implementation before proceeding
with the dependent decision; continue independent work. Do not choose whichever
interpretation makes the current run pass.

## Evaluation and submission

The [submission workflow](../.github/workflows/submit-app-store-review.yml)
and [submission CLI](../scripts/submit-app-store-review.py) default to
`release_evidence_mode=enforce`: App Store submission fails closed when required
evidence is missing. Shadow mode evaluates the same configured policy for
diagnostics; it does not approve a submission.

## Capture before review

1. Read the owning plan and identify the exact previous/current source and
   signed build identities. Generate the full comparison with every archive
   layout's expected-build manifests; every platform ships in the release.
   Follow [the release procedure](release.md);
   do not filter or rewrite `requiredEvidence` or `requiredSurfaces`.
2. Prepare visual requirements from the canonical matrix and the comparison's
   fresh visual classes. The full release evaluator must resolve eligible
   carry-forward from valid lineage; a smaller current review queue does not
   waive the complete evidence requirements.
3. Open an exact-build runtime session only when the comparison requires it,
   using exactly `requiredSurfaces.actual-runtime`. Follow the canonical
   Production runtime/cache checks in [Validation](#validation). Observe normal
   install and receipt propagation through the coordinator before requesting
   manual recovery.
4. For shared views, supply all required capture inputs to the
   [supported capture path](signed-validation-galleries.md). If inputs are
   missing, correct the invocation as machine work. Every shared-view surface
   has a capture mechanism; a cell that was not captured is a failed capture,
   not a reason to navigate a signed gallery.
5. Run `record-reference-approvals` (see [reference images](#reference-images)).
   It approves each captured cell that matches an unchanged reference.
6. Send Chris only the remaining cells, in one batch, and record his decision
   for each. When he accepts a changed cell, commit that captured image as its
   reference. OS-composited placement remains a separate physical review with
   its own exact-runtime prerequisites.
7. Evaluate the complete evidence with the full release gate and validate its
   reconstruction using the same authoritative inputs. Release must bind the
   selected approved RC. Neither a successful capture nor a completed
   coordinator slice establishes full release approval.

## Implemented capture limits

The executor captures iOS, iPadOS, visionOS, watchOS, and tvOS cells on
simulators. tvOS capture requires current product source that contains the
tvOS validation launch route; older source fails qualification by design.
`macos.app` and `macos.widget` are rendered on the host by a SwiftPM tool the
executor builds from the verified source root, with no app or extension bundle;
see [the capture contract](signed-validation-galleries.md#private-simulator-capture).

## Reference images

Every shared-view cell has a committed reference PNG at
`Tests/SharedViewReferences/<surface>/<cell>.png`. Two CI jobs draw the cells
the way Shared-View Capture Evidence does and compare them with
[`scripts/context-panel-shared-view-references.py`](../scripts/context-panel-shared-view-references.py):
`shared-view-references` renders the macOS cells on the host, and
`shared-view-simulator-references` builds the Release simulator products and
captures the iOS, iPadOS, visionOS, watchOS and tvOS cells. A cell matches when
its size is the same and only a few pixels differ beyond a small per-channel
tolerance (the constants live in
[`scripts/context_panel_shared_view_references.py`](../scripts/context_panel_shared_view_references.py)).
A changed or missing reference fails the job.

The jobs run only when a change can affect them (see
[`scripts/ci-change-scope.py`](../scripts/ci-change-scope.py)).
`shared-view-references` runs on pull requests and merge-train candidates.
`shared-view-simulator-references` takes about an hour, so it does not: it runs
after a change lands on `main`, one run at a time with a newer merge replacing a
running one, and on a manual CI run. The exception is a pull request that
changes a committed reference image: the look of a cell changed, so that pull
request also runs the simulator job and re-records every surface before it
merges. Nothing waits for it on `main`. A failure there opens a plan issue
titled "Simulator reference images fail on main", or comments on the open one,
naming the changed cells; the next passing run on `main` closes it
([`scripts/ci-reference-failure-issue.py`](../scripts/ci-reference-failure-issue.py)).
A change that alters only the simulator cells still surfaces through that
issue after it lands. Runner image drift shows up in the next of these runs, and at release the
capture compares every cell with its reference on the current runner. The capture
retries a failed cell once in a fresh simulator when the rest of its platform
captured, so one flaky cell does not fail the job. App Store submission refuses
a build whose source commit has no passing `shared-view-simulator-references`
job; see [the release procedure](release.md#app-store-review-submission).

Each image shows the surface in the frame its host gives it, not the gallery
screen: a widget in its family size with the widget corner mask, a Watch
complication in its face frame and mask, the Top Shelf banner with its corner
mask, and an app presentation filling its content area. The frames live in
[`SharedViewFrame`](../Sources/ContextPanelValidationGalleryUI/SharedViewFrame.swift)
and `ValidationGalleryFamily.frame(on:)`. Dates come from fixed fixture times in
the `en_US_POSIX` locale and UTC. The Watch status-bar clock, which nothing can
pin, is painted out by a masked region.

[`Config/ContextPanelSharedViewSimulators.json`](../Config/ContextPanelSharedViewSimulators.json)
pins the Xcode, simulator runtimes, devices and masked regions both jobs and the
release capture use; a runner without them fails instead of capturing on another
simulator. References are valid only for those pins and the `macos-26` runner
image. When a PR changes how a cell looks on purpose, or the toolchain changes,
re-record:

1. For a toolchain change, update the pins file first: the Xcode, each runtime
   and device the runner offers, and each masked region if the device changed.
2. Download the `shared-view-rendered-*` artifact from the PR's CI run. For
   the simulator cells, run CI on the PR branch by hand
   (`gh workflow run ci.yml --ref <branch>`) and download its
   `shared-view-simulator-rendered-*` artifact. Each `report.json` lists every
   cell as matched, changed or missing-reference.
3. Look at every changed cell.
4. Copy them over the references and commit:

   ```sh
   scripts/context-panel-shared-view-references.py compare \
     --rendered <host-artifact> --surface macos.app --surface macos.widget --update
   scripts/context-panel-shared-view-references.py compare \
     --rendered <simulator-artifact> --simulator --update
   ```

Do not record references on a local Mac; its OS, fonts and simulators differ
from the pinned runner.

At release, after a qualified capture, approve the unchanged cells:

```sh
scripts/context-panel-validation.py record-reference-approvals \
  --version <version> --build-number <build-number> \
  --surface-comparison <comparison.json> \
  --current-manifest <current-source-manifest.json> \
  --previous-manifest <previous-source-manifest.json> \
  --capture-receipt <shared-view-capture-receipt.json> \
  --captures <directory-with-captured-pngs>
```

The inputs are the capture run's public evidence and its private PNGs. The
command refuses a receipt that fails the capture lane's qualification and a
manifest whose ID does not match its contents, then reads both references from
Git at the source commits those manifests name. It approves a cell only when
the captured image matches the candidate's reference and that reference matches
the previous release's. A missing, new or changed reference, a changed image, or
a capture that does not match the receipt leaves the cell for Chris. It never
replaces a recorded decision and never touches actual-runtime or placement
requirements.

Existing Mac render tests can export host-rendered PNGs, but those test outputs
are not formal build/requirement-bound capture receipts. The default-text matrix
case and an enlarged-text stress test are distinct valid scenarios. Preserve the
stress coverage; do not relabel it as evidence for a different matrix context.

Simulator or host-rendered shared views cannot satisfy `actual-runtime` or
`os-composited-placement`. Preserve historical manifests, receipts, and fixture
contracts, without silently upgrading diagnostic or reference-only evidence.

## Validation

Before changing or validating app/widget/provider behavior, identify the active
runtime. Mixed runtimes caused repeated false positives during App Store release
prep, so treat them as a blocker rather than background noise.

The only valid local runtime for app/widget testing is the canonical installed
app:

```text
/Applications/Context Panel.app
```

Do not test app, widget, login-item, provider, sandbox, or storage behavior from
an arbitrary DerivedData, `.build`, `/tmp`, or worktree app bundle. Build outputs
are allowed as intermediate artifacts only. For Development-runtime testing,
the runtime gate installs the fresh build to `/Applications/Context Panel.app`,
registers that app and its embedded widget, and quarantines or unregisters
competing bundles with the same bundle identifiers. For signed Production,
TestFlight, or App Store validation, preserve the installed app and use the
read-only Production receipts below; do not replace it with a Development build.

Before telling Chris the app/widget are ready to test, run the runtime baseline
receipt and require it to pass:

```sh
scripts/context-panel-runtime-baseline.sh check
```

For TestFlight, App Store, or other signed Production companion validation, use
the read-only Production receipt and require both the app and refresh agent to
report `Production` CloudKit:

```sh
scripts/context-panel-companion-cache.sh preflight
scripts/context-panel-runtime-baseline.sh check --require-production-runtime
```

When the approved signed candidate predates the validator checkout, select its
recorded identity with the sealed expected-build manifest from that release's
archive/upload artifacts:

```sh
scripts/context-panel-runtime-baseline.sh check --require-production-runtime \
  --candidate-manifest <ExpectedBuildManifest-macos.json>
```

This runs the current validator's checks against the candidate's recorded
fingerprint. It verifies the installed signature, version/build and embedded
manifest/contract identity, and requires all three macOS surfaces to match the
record. Missing or invalid manifests, different builds and unrecorded source
identities fail; there is no fallback to the installed stamp. Repeat
`--candidate-manifest` for multiple archive layouts from the same candidate.
The coordinator forwards its existing repeated `--expected-build-manifest`
inputs to this path for status, final reports and Mac launch verification.
These inputs select candidate identity; the release gate still owns approved
RC lineage and human approval. Without a candidate manifest, the baseline
continues to compare against its checkout. The candidate option is check-only.

Spotlight bundle discovery has a bounded deadline. A timeout or unavailable
discovery fails the receipt as an incomplete conflict inventory and stops
install/reset before runtime teardown; partial results never establish a clean inventory.

The baseline verifies each running refresh agent's loaded executable path and
vnode (device/inode) against the canonical installed helper. It reads launchd's
PID even when the process command is only the bundle identifier. A moved,
trashed, replaced, or unreadable loaded executable fails the receipt; installed
bundle entitlements and a running launchd job alone do not prove its identity.
After a normal TestFlight install and background-update recovery, rerun the
same read-only check once the loaded helper belongs to that installation.

Require the companion cache preflight to report `preflight=OK` before opening a
signed validation coordinator session or judging physical-device behavior. If it
fails, inspect the exact `companion-build-validation` root and use only the
repo-owned explicit-root quarantine command; do not broadly delete DerivedData
or the artifact cache.

For routine physical watchOS complication testing, first confirm that the new
build has reached the Watch, then restart the Watch before judging complication
UI or behavior. The current TestFlight/watchOS runtime can keep the previous
WidgetKit extension or render active until a post-install restart, so do not
treat pre-restart stale or blank complication output as an application-code
regression. Skip the restart only when Chris explicitly asks to investigate the
in-place upgrade path; in that case preserve existing placements and capture the
installed build, face state, app diagnostics, and extension-process evidence
before any recovery action. Do not use uninstall/reinstall or complication
reselection as the routine workaround.

`record-watch-restart` records the operator's confirmation, not an automatic
restart. Its exact-build observation uses either CoreDevice's current Watch
installation or, when the Mac cannot see the Watch, all of these together:

- A read-only App Store Connect `betaTesters.appDevices` record for the selected
  tester and paired iPhone model shows the exact version and build. The Watch
  app ships inside the iPhone app; Apple does not list it separately there.
- The active exact-build coordinator holds validated runtime receipts for both
  `watchos.app` and `watchos.complication`.
- Both receipts were written strictly after the confirmed restart time or its
  operator-supplied lower bound, and no later than the attestation.

For the remote route, supply the restart bound and private tester selection:

```sh
scripts/context-panel-validation.py record-watch-restart \
  --version <version> --build-number <build-number> \
  --restarted-at <ISO-8601-time-with-timezone> \
  --tester-email <tester-email> --paired-iphone-model <iPhone-model> \
  --asc-env-file <private-asc-env-file> --json
```

Invoking the command confirms that the operator restarted the Watch after that
build was installed. Without `--restarted-at`, the CoreDevice route uses the
attestation time as the restart lower bound; the remote route refuses. The
record saves the observation route, restart bound, ASC read time and Watch
receipt references, without tester emails or device identifiers. This proves
build observation for the restart attestation only. It does not replace runtime
validation, physical complication placement review, or any other release gate.

Never run `install` or `reset` while preserving a signed Production publisher.
Those modes build a local Debug runtime with Development CloudKit and now refuse
to replace a Production, TestFlight, App Store, or unverified canonical app.

After rebuilding or reinstalling during normal development, use the in-place
install gate. This is the Development runtime path: it updates
`/Applications/Context Panel.app` and verifies the same runtime receipt while
preserving the user's placed widget:

```sh
scripts/context-panel-runtime-baseline.sh install --launch
```

For a Development runtime, use the full reset gate only when Chris explicitly
asks for a fresh install or container/storage reset, or when cleaning up a mixed
Development runtime. The signed Production/TestFlight protection above also
applies to mixed-runtime cleanup:

```sh
scripts/context-panel-runtime-baseline.sh reset --launch
```

Do not claim readiness unless the receipt shows `baseline=OK`, the running app
process in `Active Processes`, PluginKit widget registration, the refresh agent,
and the `contextpanel://` URL handler all point to
`/Applications/Context Panel.app`, and the build fingerprint in that app matches
the selected recorded candidate (or the current source tree without a candidate
manifest). A receipt that says `OK: no Context Panel processes are
running` is acceptable only for passive cleanup checks; it is not enough before
asking Chris to test app, widget, provider, sandbox, storage, or login-item
behavior. If the app was closed, launch the canonical app with
`open -a "/Applications/Context Panel.app"`, rerun the baseline check, and require
the active process path to be the installed app before saying it is ready to test.
When a fresh install was requested, also require the storage/cache check to
report no persisted account config, bookmarks, snapshots, widget timelines,
background-refresh settings, limit-warning settings, limit-warning notification
state, pending limit-warning notifications, webhook settings, webhook delivery
state, or webhook credentials.
Treat any mismatch as a blocker. Avoid repeatedly opening `contextpanel://`
during ordinary validation; use that only for explicit widget click-through
testing, because URL activation can change the visible app window state.
For launched app/widget readiness, the WidgetKit cache receipt must show real
Context Panel render snapshot or timeline files; placeholder-only Chrono cache
files are a blocker even if WidgetKit has cache files on disk.

The install gate is the normal "ready to test" path. The reset gate can make
macOS refresh widget registrations and may still disturb placement; after a
reset, verify whether the widget is still present before asking Chris to test
widget UI. Do not clear WidgetKit/Chrono placement directories or restart
`chronod` unless explicitly testing widget placement/reset behavior; use
`--reset-widget-placement` only when removing the widget from the UI is
acceptable.

- Record the current branch, default branch, and dirty state with
  `git status --short --branch` before editing, packaging, or installing.
- Do not package or install from a dirty multi-workstream tree unless Chris
  explicitly asks for a scratch dogfood build. If the tree already contains
  broad unrelated changes, pause and propose a cleanup/split plan first.
- Before judging UI, widget, login-item, provider, sandbox, or storage behavior,
  verify that the foreground app process, WidgetKit extension, URL handler, and
  refresh agent all resolve under `/Applications/Context Panel.app`. A DerivedData
  app, widget, or login item is a mixed runtime and must not be called fixed.
- Auto-review or agent worktrees must not leave globally registered WidgetKit or
  LaunchServices bundles behind. Prefer `swift build` and focused `swift test --filter` for review
  work. If an agent must build the Xcode app target, check for stale
  DerivedData, `/tmp`, and repo `.build` app/widget registrations
  afterward. Apply the runtime-specific cleanup rules above; do not run
  `install` or `reset` while preserving a signed Production publisher.
- For signed/App Store-style validation, terminal success is not proof that the
  app works. Reproduce provider reads from the signed app or signed refresh
  agent, because sandbox, TCC prompts, security-scoped bookmarks, app groups,
  and login-item environment differ from an interactive shell.
- When touching app groups, widget mirrors, bookmarks, account IDs, or snapshot
  merging, inspect the active storage roots before and after validation:
  `~/Library/Application Support/Context Panel`,
  <!-- markdownlint-disable-next-line MD013 -->
  `~/Library/Group Containers/MM5YXC7T6E.group.com.shinycomputers.contextpanel/Context Panel`,
  and
  <!-- markdownlint-disable-next-line MD013 -->
  `~/Library/Containers/com.shinycomputers.contextpanel.widget/Data/Library/Application Support/Context Panel`.
- Snapshot merge or account-ID changes must include a duplicate-account check.
  Preserving failed provider data is useful, but old logical account IDs must not
  accumulate as separate live lanes.
- App Store/TestFlight work must not remove, hide, or narrow product UI such as
  provider setup, diagnostics, history, settings, or account management without
  an explicit product decision from Chris.
- Before planning, uploading, or submitting an App Store/TestFlight build, read
  the versioning flow in `docs/release.md`. Release trains use the workflow
  `version` and `build_number` inputs, not a source-controlled bump to
  `project.yml`; every new shippable train after an accepted or rejected App
  Store version needs a fresh marketing version/build input, and the uploaded
  build's pre-release marketing version must match the App Store Review version.
- When Chris asks to check App Store Connect through the API, follow
  [Direct App Store Connect API Checks](release.md#direct-app-store-connect-api-checks).
- CloudKit Production schema validation follows the
  [CloudKit Production Schema Gate](release.md#cloudkit-production-schema-gate).
  It gates operations that put a build in front of people; do not extend it to
  App Store Connect writes that are independent of the build and schema, such
  as screenshot upload.
- Physical companion dogfood installs should clean stale Context Panel
  development provisioning profiles from the target device while preserving the
  profile embedded in the newly installed build and preserving App
  Store/TestFlight profiles. Use
  `scripts/cleanup-context-panel-device-profiles.sh --device <id>` for manual
  hygiene; the visionOS dogfood fixture calls it by default. Use
  `--no-profile-cleanup` only when investigating profile state itself.
- Before opening a signed validation coordinator session, compare the previous
  and current full source manifests with
  `scripts/context-panel-surface-manifest.py compare --train <beta|rc|release>`.
  Comparisons intended for release-gate, report-validation, or submission use
  repeated `--previous-expected-build-manifest` and
  `--current-expected-build-manifest` arguments covering every archive layout;
  source-only comparisons are diagnostic and cannot enter the signed gate.
  Do not open a runtime session when `requiresRuntimeSession=false`;
  automated shared-view evidence is the gate for render-only changes. When runtime proof is required, pass only the surfaces in
  `requiredSurfaces.actual-runtime` through repeated `--surface` arguments.
  `requiredEvidence`/`requiredSurfaces` are authoritative; `freshEvidence` is
  explanatory delta metadata and is not a complete gate. Simulator builds and
  galleries can satisfy shared-view evidence only; they never satisfy
  `actual-runtime`, which must come from the exact signed artifact.
  `requiresPlacementReview=true` remains a separate physical/OS-composited
  review requirement. Every train re-checks only what changed: a rebuild alone
  needs no new runtime proof, and unchanged surfaces carry forward their
  approved evidence.
- After the coordinator final report is available, evaluate the full comparison
  with the [release evidence gate](release.md#release-evidence-carry-forward-gate).
  Do not filter or rewrite `requiredSurfaces`.
- Keep Validation Gallery access operator-only. Normal Mac, companion, Watch,
  and Apple TV product UI must not expose gallery buttons, toolbar actions, list
  rows, or runway items. Use the allowlisted signed routes and the bounded Watch
  launch argument documented in `docs/signed-validation-galleries.md`; do not
  add a runtime feature flag or persistent unlock.

Minimum runtime evidence before saying a signed dogfood build is ready:

```sh
git status --short --branch
ps axww -o pid,ppid,command | rg -i 'Context Panel|ContextPanel|RefreshAgent'
pluginkit -m -A -D -vvv | rg contextpanel
lsof -p <refresh-agent-pid> \
  | rg 'ContextPanelRefreshAgent|/Applications/Context Panel.app'
codesign -d --entitlements :- "/Applications/Context Panel.app" 2>/dev/null
shasum -a 256 \
  "/Applications/Context Panel.app/Contents/MacOS/Context Panel"
```

If any of those point to different build roots or unexpected entitlements, stop
and report the mixed-runtime state before making more fixes.

Source-only validation follows the [test rules](../AGENTS.md#test-rules).
Installed-runtime, release and visual evidence above still applies when those
behaviors change.

In CI, [`scripts/ci-change-scope.py`](../scripts/ci-change-scope.py) decides
which jobs a change needs; its docstring owns the rules.
When adding a build input outside `Sources/`, `Tools/`, and `Config/` that
lives under `docs/`, `Tests/ScriptsTests/`, or a Python script, list it in that
script rather than widening the skip rules.

For UI work, also run the native app/widget locally and inspect the actual macOS
presentation before calling the work ready.

For widget/app UI changes, the SwiftPM gate is not sufficient by itself. Use the
Development install gate (`install --launch` above) instead of manually opening
or copying DerivedData builds; it regenerates the Xcode project, builds the real
Xcode app target, installs the fresh app to `/Applications/Context Panel.app`,
refreshes the app/widget runtime, and prints the runtime receipt.

Do not create backup copies of `/Applications/Context Panel.app` during normal
development installs.

The installed widget can still be older than the rebuilt app. Check
`pluginkit -m -A -D -vvv | rg contextpanel` and verify the registered extension
path is under `/Applications/Context Panel.app`. If WidgetKit is registered to
any other path, report the mixed runtime and follow the runtime-specific rules
above before judging the widget. Preserve signed Production/TestFlight apps and
use `check --require-production-runtime`; that check diagnoses the mismatch and
does not itself repair competing registrations. Use the reset gate only when
the Development-runtime conditions above apply.

The app, widget, refresh agent, and Claude cache scripts use
`MM5YXC7T6E.group.com.shinycomputers.contextpanel` as canonical shared storage.
Do not reintroduce `group.com.shinycomputers.contextpanel` as a runtime fallback;
probing that container can trigger macOS protected app-data prompts in local
builds and can split app/widget state. A wildcard Mac Team provisioning profile
may not carry the app-group entitlement, which can make the widget show a
`current-snapshot.json` read error even while the app can read data. For release,
use a provisioning profile with the app group enabled. For local development,
prefer an ad-hoc-signed install over a wildcard profile when testing the live
widget. If building with `CODE_SIGNING_ALLOWED=NO`, ad-hoc sign the app,
extension, and debug dylibs with their entitlements before installing. The app
also mirrors the current snapshot to the widget extension container as a
local-development fallback. The app-side copy path is the widget container under
`~/Library/Containers`, while the widget reads it through its sandbox-local
Application Support directory; keep that split in mind when debugging why the app
and widget disagree.
