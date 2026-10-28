# macOS And Companion Release Path

Start with [Validation Authority and Operator Route](validation-authority.md)
for the validation contract and supported capture path.

Context Panel's normal release path is the GitHub Actions `Ship` workflow.
One run builds every platform from one commit with one marketing version and
one build number:

- GitHub Release zip artifact, signed and notarized
- Mac App Store Connect build upload, signed with Mac App Store profiles
- iPhone/iPad (with the embedded Watch app), Vision Pro, and Apple TV App Store
  Connect build uploads
- TestFlight beta distribution for every uploaded build

Treat live review state as App Store Connect-owned operational data and verify
it directly before release decisions.

App Store Review submission is intentionally separate from `Ship`. Run it only
after the TestFlight build has been validated and the App Store release decision
is explicit.

## Definition of released

Every platform ships together as one release, with one version and build:
Mac, iPhone and iPad with the embedded Watch app, Vision Pro, and Apple TV
([Q451](https://github.com/cbusillo/context-panel/issues/835#issuecomment-6235390539)).
Each release re-checks only what changed since the last one; unchanged
surfaces carry forward their approved evidence.

A release is complete only when every shipping channel is current for each
shipping platform: the signed/notarized GitHub Mac artifact is published,
the intended builds are available to the intended TestFlight testers, and the
exact App Store builds have been submitted, approved, and verified live on the
public App Store. iOS includes iPadOS and its embedded Watch app; Mac, visionOS,
and tvOS have independent store versions. A skipped companion channel does not
make that platform current. An intentionally scoped beta or upload can finish
its stated scope, but cannot be reported as a completed product release.

Session closeout, issue finish lines, and Supervisor reports link here and
name the channel result: **GitHub published**, **uploaded to App Store Connect**,
**available in TestFlight**, **App Store submission pending**, **in review**,
**rejected**, or **live on the App Store**, per platform. Include the version,
build number, source, evidence, and next actor/command for unfinished delivery.
Do not use an unqualified “shipped” or “released” for uploaded/TestFlight work.
Merging source is separate from all of these channel results.

### Durable handoff and public drift

Ship's summary creates an issue for each successful platform upload, even when
another channel fails; the three companion uploads report together, so their
issues are created once all three succeeded. The issue records **App Store submission pending**, the
exact uploaded identity, channel results, run link, and the `Submit App Store
Review` workflow command with `dry_run=true`. Failure to record it fails Ship's
summary job. Retries reuse the same platform/version/build/source record.
The release agent owns TestFlight validation and the existing submission gates;
recording a pending issue grants no submission authority. The record stays
open until the exact build is verified live. Submission, rejection, and
approval updates belong on the same issue. A real `Submit App Store Review` run
(not a dry run, cancel or prepare-only run) marks the matching record as
submitted. A build uploaded outside Ship has no record, so the check cannot
watch it: the run warns, and the check keeps its previous target for that
platform. A record whose build is replaced as the candidate never goes live:
close it as not planned, with a link to the replacing record.

When Ship's optional `release_issue` input names the release's open plan issue,
each record Ship creates becomes a native sub-issue of it. Retries keep the
existing link, and a record that already belongs to another release fails the
summary job rather than moving.

`App Store Release Status` runs every six hours and can also be dispatched
manually. `scripts/app-store-release-status.py check --lag-hours 48` reads the
public US storefront separately for each platform and compares its numeric
marketing version with that platform's newest build submitted for review.
Before any build on a platform is submitted, it uses the newest upload, so a
release that stalls before submission still alerts; a TestFlight-only build
uploaded after a submission raises no alert. It also
uses the latest sealed GitHub Mac publication as a baseline, including releases
predating these records; that baseline explicitly leaves upload and TestFlight
state unknown. Other platforms are tracked when selected for a successful Ship
upload, never inferred from a Mac release.

After 48 hours from the submission (from the upload for a build not yet
submitted, or GitHub publication for the legacy Mac baseline), lag produces an alert comment on that durable issue and a failing
workflow signal for Supervisor watchers. This also catches a release stalled
in review or rejected without querying or changing App Store Connect. An
unreadable or changed public page alerts as **unknown**, immediately. Identical
observations produce no duplicate comments; a later recovery is recorded.
Records closed as completed still participate, so premature closeout cannot
hide drift; records closed as not planned are excluded from alert targets.
No store credentials or store writes are used. The public page parser verifies
the requested app/platform; it never substitutes another platform's version.
Public listings do not expose the exact build number, so public version
equality alone reports only “public version current”. The check closes a record
as completed, with that proof in a comment, when the public version equals the
record's version exactly, the record carries a submission marker, and it is the
only record submitted for that platform and version: a version can have only
one build live, so that build is the live one. Two or more submissions for the
version, a submission made without a Ship record (which marks every existing
record of that platform and version), an unreadable page, or a record never
submitted cannot prove that build live.

Separately, the check reconciles every platform record, including older records
that are no longer alert targets. A strictly newer public version on the same
platform closes an open record as **not planned**, with a comment naming the
newer version. This is supersession, not proof that the old build went live;
it also covers skipped TestFlight uploads and withdrawn submissions. Equality,
an older public version, and unknown public evidence never qualify as
supersession. A newer upload or submission alone does not qualify either.

After each run, the check reads the native parents of all platform records. It
closes a release parent once every sub-issue is closed, all four platforms have
records, and this run verifies every platform record either live with the
single-build proof above or superseded by a newer public version. Hand closure
alone cannot complete a release, and moving the alert targets to a new release
does not strand the old parent. The summary names each record's outcome without
claiming superseded builds were released. A parent with the `plan` label moves
to `plan:done`. Closing
may lag Apple's release by up to six hours. The check does not submit,
approve, release, or change App Store Connect, or alter submission evidence
policy.

## Release cadence

TestFlight and App Store releases run on different clocks.

- **TestFlight (internal):** ship whenever a change is worth trying on a
  device. A TestFlight build needs no device proof round, only the one Ship
  run. Chris installs on the Mac from TestFlight when a check needs the
  installed app.
- **App Store:** bundle finished work into fewer releases. Each App Store
  release pays for one proof round covering whatever changed since the last
  App Store release. Any `ContextPanelCore` change means every device. Agents
  suggest an App Store release when user-facing changes have built up, or when
  a fix matters to users. Chris decides.
- **Fixes users are waiting for** go to the App Store promptly, even alone.
- **One release at a time per platform:** don't start the next App Store round
  while one is in review, unless it replaces a rejected build.

## Before starting a release

Follow the overall [release direction](https://github.com/cbusillo/direction/blob/HEAD/DIRECTION.md).
For Context Panel, the [recorded Q94 decision](https://github.com/cbusillo/context-panel/issues/752#issuecomment-6062518684)
sets the operator preflight: name Chris's release request or the approved issue
whose finish line requires the change installed. Post the list of changes since
the last release on the release's owning issue **before dispatching Ship**.
Check that every listed change is finished; stop if any is unfinished. Apply
this preflight to standalone workflows too when they publish, upload, distribute or
submit a build, including recovery. Artifact-only and dry-run validation remain
ordinary engineering on their existing guarded paths.

A configured `Ship` run requires **zero human environment approvals**. Its
secretless `Record Release Intent` job uses the existing `release-approval`
environment to record standing acceptance. After it succeeds, `Validate Release
Intent` preflights App Store versions and resolves the build number using
`release`. All signing, notarization, upload, CloudKit-receipt and TestFlight
jobs use `release` as their only secret environment, alongside inherited
repository secrets. Keep each credential in one store. Both environments have
no reviewer or wait timer; `release` accepts only protected `main`.
The intent environment contains no secrets.

The four reusable channels identify Ship through `github.workflow_ref`, GitHub's
caller identity. This repository's `ship.yml` on `refs/heads/main` skips their
standalone intent job because Ship already recorded it. Other callers and direct
dispatches record their own intent automatically before using `release`.
App Store Review submission and screenshots also record intent automatically.
Callers grant `actions: read` and at least `contents: read`; GitHub Release
publication requires `contents: write`. Channel jobs reject failed or cancelled
guards and failed intent jobs. The skipped-intent path remains limited to the
exact Ship caller. Ship's TestFlight join requires successful validation and
every selected upload before distributing any build.

Ship passes repository secrets to each same-commit local channel workflow with
`secrets: inherit`. GitHub does not automatically forward repository secrets to
reusable workflows; selecting `environment: release` in the called job supplies
that environment's secrets, not the caller's repository secrets. Existing
repository entries can therefore stay in their current store without copying or
moving values. The intent gate consumes no secrets, and channel calls still
require successful validation. The environment and inheritance semantics
are covered in [Reusable-workflow coverage](#reusable-workflow-coverage).

Dispatch release workflows from `main`. Before any environment job, the
secretless trust guard verifies the protected ref, checked-out commit, main
ancestry, version, and build number. A second secretless check refuses new runs
unless the repository variable `RELEASE_APPROVALS_CONFIGURED` is exactly `true`.
Before any environment job, a read-only metadata check requires `release` and
`release-approval` to have no required reviewer or nonzero wait timer in the
reported protection rules. Missing environments, incomplete metadata and an
unavailable API fail closed. It also verifies that `release` accepts only `main`.
CI's `--probe` checks the secret store; release guards check both environments.
Both use the built-in workflow token and metadata endpoints, never secret values.
The existing activation variable remains the supported pause switch: unset it
or set it to `false` to refuse new runs before environment jobs. Each pending
channel guard reads it again; jobs whose guards passed are unaffected. It does
not restore reviewer rules. `RELEASE_CHANNELS_CONFIGURED` and `release-channels`
remain unused.

Retry failed channel jobs through the original run and its evidence-recovery
rules. Historical runs retain their original workflow and may still expect
review; source changes do not rewrite them. Do not dispatch or rerun a release
solely to test this change. Signing, notarization, exact-source CloudKit schema
receipts and signed validation evidence remain required on their existing paths.

Protected-main workflow changes remain trusted: environment branch rules do
not restrict secrets to a workflow filename. Classify new release jobs and their
intent dependencies in the checker, and obtain the model review required for
approval changes. `scripts/check-release-approvals.py` lints the parsed workflow
graph in CI and prints an all-channel structural dry-run plus secret names,
never values. It checks one secretless Ship intent job, standalone intent paths,
success dependencies, repository-secret inheritance on all four local channel
calls, and a single secret environment. The one classified non-channel job is
`Submit App Store Review`'s `record-submission`: it needs only the submit job,
holds no secrets or environment, and may only read contents and write issues.
It cannot verify live
reviewer settings or actual secret placement. In unclassified workflows, it
rejects names that could select `release`, `release-approval`, or the retired
`release-channels`, including opaque expressions such as
`${{ vars.CHANNEL_ENV }}`. Environment names are compared without regard to
case, matching [GitHub's environment naming rules](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments).

Unrelated environments have two supported routes: a literal name such as
`staging` or `release-notes`, or simple context lookups inside a fixed unrelated
namespace, such as `preview-${{ inputs.target }}` or
`${{ needs.prepare.outputs.target }}-preview`. Simple dotted lookups from
`github`, `inputs`, `vars`, `needs`, `strategy`, and `matrix` are treated as any
string, including empty; the fixed parts must rule out all three reserved
names. Complex expressions (functions, operators, bracket lookups) are opaque
and refused; rewrite unrelated selection using the supported namespace route.
An actual release workflow must join the classified release graph instead.
The checker never reads variable values or evaluates GitHub Actions code, and
the classified workflows' no-click contract and protected-main checks remain
unchanged. Repository secrets themselves have no environment branch restriction:
a different same-repository branch workflow can reference them without entering
`release` or its guarded path. This existing repository-scope exposure is not
changed by forwarding; the Ship checks govern this release path, not every
possible consumer of a repository secret.

## Reusable-workflow coverage

The report's `reusable_workflow_coverage` lists job-level calls outside the
classified release graph, including local calls and remote calls pinned to a
commit, tag or branch. These calls remain supported. Any listed call sets
`complete: false` and prints a coverage warning (an annotation in GitHub Actions);
exit success still means the
classified graph passed, not that every called job follows the classified
release path.
Step-level actions are not reusable-workflow calls. Local workflow documents
still receive the environment-name check above, but their unclassified call
dependencies are not qualified. Remote jobs and nested calls are never fetched
or executed by this linter. The report contains call references, not inputs,
secret mappings or secret values.

GitHub's [reusable-workflow documentation](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows#using-inputs-and-secrets-in-a-reusable-workflow)
distinguishes explicitly passed or inherited secrets from environment secrets:
a called job can declare its own environment and use that environment's
secrets. The [caller context persists](https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations#github-context),
and a calling job cannot declare an environment. Therefore, omitting
`secrets: inherit` does not prove a remote call cannot reach an environment
store. A main-branch caller of an accessible remote workflow whose job selects
`release` is a potential secret-store path outside the classified graph. This is
an inference from documented semantics, not a live credential-access result;
no external workflow was run to qualify this assessment. Actual exposure also
depends on Actions access policy and the selected callee's jobs.

For an unrelated reusable call, inspect the exact callee and any nested calls
during protected-main source review; prefer an immutable commit reference and
check environment selection, secret use and intent dependencies. A call can
remain accepted with incomplete coverage; it is not a classified-graph proof. New
release behavior must join the classified graph and its model-review route.
A blanket ban, exception allowlist or new blocking approval policy needs a
separate Director decision. The no-click graph remains unchanged.

## Release environment check

Local agents run the metadata checker through the configured automation helper
from the [GitHub skill](https://github.com/cbusillo/codex-skills/blob/main/skills/github/SKILL.md):

```sh
CONTEXT_PANEL_ENVIRONMENT_GH="<github-skill>/scripts/gh-with-env-token" \
  GITHUB_REPOSITORY=cbusillo/context-panel \
  uv run --no-project python scripts/check-release-approval-environment.py
```

Replace `<github-skill>` with the installed skill directory. This performs GETs
only. CI uses `--probe` to check only the secret store; workflow guards use the
built-in token and full mode to check both environments.

The lower-level workflows remain callable for recovery and validation:

- a GitHub Actions release workflow that builds the native Xcode app and widget
  extension, signs the bundle, notarizes by default, uploads workflow
  artifacts, and creates a GitHub Release
- a GitHub Actions App Store Connect Build Upload workflow that archives the native
  Xcode app, widget extension, and refresh-agent login item with App Store
  provisioning profiles, then exports or uploads the package to App Store
  Connect
- a GitHub Actions App Store Connect Companion Build Upload workflow that
  archives the iOS/visionOS companion app with its embedded WidgetKit extension,
  or the standalone tvOS app, with platform-matching App Store provisioning
  profiles, then exports a signed IPA or uploads the archive to App Store Connect
- a GitHub Actions TestFlight Beta Distribution workflow that waits for an
  uploaded build to finish App Store Connect processing, then assigns it to
  TestFlight beta groups
- a GitHub Actions Submit App Store Review workflow that attaches an uploaded
  build to an App Store version and can also run cancel-only review recovery
- a native Xcode app target with an embedded WidgetKit extension, generated by
  XcodeGen
- an interim SwiftPM wrapper script for quickly sharing the preview app without
  the widget extension

The native Xcode path is the one to use for widget installability.

## Runner And Xcode Policy

Do not use `macos-latest` for release or App Store Connect upload jobs. GitHub's
floating macOS image can lag App Store Connect SDK requirements, which makes
failures arrive late during export/upload instead of before signing starts.

Routine Swift build/test validation jobs should use the repository self-hosted
runner labels `[self-hosted, macOS, ARM64, context-panel]`. That runner is
intended for fast compile/test feedback on the primary local development host.
Same-repository pull requests, pushes to `main`, scheduled scans, and manual
dispatches are trusted runner inputs and may use the self-hosted runner for both
routine Swift validation and CodeQL. Fork pull requests must stay on an explicit
GitHub-hosted macOS image so untrusted PR code does not run on the persistent
self-hosted machine. Persistent SwiftPM and DerivedData cache roots belong in
runner-local environment configuration, not in tracked workflows or scripts;
tracked jobs namespace mutable cache content under
`checkouts/<physical-checkout-path-hash>/` so concurrent checkouts do not share
build state. Explicit SwiftPM and companion DerivedData path overrides remain
exact, and tracked jobs fall back to checkout-local build directories when the
runner cache or path-hashing tool is unavailable. Runtime install/reset cleanup
continues to inspect both the legacy shared companion DerivedData layout and all
checkout-scoped layouts.

Release, App Store Connect upload, and companion upload jobs should use explicit
GitHub-hosted `macos-26` while App Store Connect accepts the Xcode 26 train. The
workflows run `scripts/validate-release-xcode.sh --required-major 26` before
signing assets are imported or archives are produced. Keep that preflight
conservative: update it only after App Store Connect release notes or a controlled
upload canary confirm that a newer Xcode train, such as Xcode 27, is accepted for
App Store/TestFlight distribution.

When Xcode 27 is officially accepted, update the release runner/image and the
preflight required major together. Until then, a macOS 27 / Xcode 27 self-hosted
runner is appropriate for fast local validation, but not the default path for
official App Store or TestFlight upload jobs.

## Normal Ship Workflow

Use `Ship` for normal releases. Its inputs, descriptions and defaults are
declared in [`ship.yml`](../.github/workflows/ship.yml).

For a normal release, run `Ship` from `main` with the defaults. That creates the
friend-installable GitHub artifact and makes every platform's App Store build
available to the selected TestFlight testers at the same version and build,
without submitting it for App Review. The summary records an App Store
submission issue for each uploaded platform; companion records are created once
all three companion uploads in the run succeeded. Recover a single failed
platform by re-running the failed jobs of the same run.

The workflow summary records the selected channels, version, build number,
target commit, notarization choice, App Store Connect upload state, and
TestFlight beta distribution state. Use the lower-level `Submit App Store
Review` workflow separately after TestFlight validation.

## CI Release

The `Release` workflow is started manually from GitHub Actions or called by
`Ship`, always from protected `main`. It builds the native `ContextPanel` Xcode
scheme, not the SwiftPM wrapper, so the artifact includes
`ContextPanelWidgetExtension.appex`. Creating a tag does not trigger the
workflow; this keeps secret-bearing execution bound to the protected branch.

Its dispatch inputs are declared in
[`release.yml`](../.github/workflows/release.yml).

The workflow always uploads the generated zip and `release-metadata.json` as a
workflow artifact. Before upload, it seals the metadata with the tag, exact
source commit, version, build number, and SHA-256 plus byte size of the zip.
When `create_github_release` is true, the publisher first requires a resolved
signing identity other than ad-hoc (`-`) and completed notarization in the
sealed metadata. Opt-out inputs cannot override this check. The workflow checks
eligibility after artifact upload, before the CloudKit receipt gate; the live
publisher repeats the check before any GitHub write. Publication then uses a
draft-first transaction:

1. An existing tag must resolve to the exact build commit. A missing tag is
   created for that commit when the draft is published.
2. The draft release notes receive a machine-readable identity record covering
   the zip and sealed metadata asset names, sizes, and SHA-256 digests.
3. Existing same-name assets are downloaded and compared byte-for-byte. Matching
   draft assets are reused. With an exact identity marker, corrupt or incomplete
   draft assets are deleted and re-uploaded; unexpected assets and identity
   drift fail closed.
4. Missing assets are uploaded without `--clobber`, downloaded again, and
   verified before the draft is published.

An interrupted upload therefore remains a draft. Rerunning the same commit and
bytes resumes or returns an idempotent success; a published release with changed
identity or bytes is never rewritten by the workflow. Repository-level GitHub
Immutable Releases are enabled, so future releases become platform-immutable
after the draft is published; draft assets may still be deleted and re-uploaded
when remote verification proves an interrupted or corrupt transfer. Signing and
notarization can produce different bytes on a fresh rebuild; if a retry reports
draft identity drift, inspect the retained draft and delete it explicitly before
starting an intentional replacement build.

Draft lookup uses GraphQL's release-by-tag lookup through `gh api`, then
REST-by-ID. Both REST and GraphQL release lists can omit drafts for the built-in
Actions token even with `contents: write`; an absent list entry does not mean
the directly selected draft is missing. Pagination still checks for multiple
visible releases for the same tag, conflicting IDs, or a changing direct
selection, which fail closed. No additional credential is needed.
A job rerun rebuilds the package; it does not reuse the
previously uploaded workflow artifact and retains the original source, including
any publisher defect. Preserve the exact zip and sealed metadata when diagnosing
a stranded draft. After source repair lands, a separately authorized release
session chooses recovery using the retained bytes or an intentional replacement.

For local command parity, see
[Build A Native App Artifact Locally](#build-a-native-app-artifact-locally).

### CI Signing And Notarization Secrets

For validation without signing secrets, dispatch **Release** with
`create_github_release=false` and `notarize=false`. It builds and uploads the
zip and sealed metadata to the workflow run, without publishing a GitHub
Release. Ship's GitHub channel always requests publication and therefore
requires signing and completed notarization. Ship rejects
`notarize_github_release=false` when its GitHub channel is selected, before
starting any channel. Standalone Release rejects the same publication intent
before building; artifact metadata remains the final publication authority.

The publication check can also run locally without secrets or GitHub access:

```sh
uv run --no-project python scripts/publish-github-release.py \
  --validate-only --tag <tag> --source-commit <full-sha> \
  --version <version> --build-number <build> \
  --title "Context Panel" --notes-file /dev/null \
  --metadata <sealed-metadata.json> --asset <release.zip>
```

This checks package metadata and sealed artifact identity; it does not perform
signing or Apple notarization. The automatic intent and protected-source checks
also apply to validation runs.

To produce a signed build, configure:

- `MACOS_CERTIFICATE_P12`: base64-encoded Developer ID Application certificate
  export. The workflow requires exactly one Developer ID identity in this
  isolated import and passes its SHA-1 fingerprint directly to `codesign`; it
  never falls back to a same-named certificate from another keychain.
- `MACOS_CERTIFICATE_PASSWORD`: password for the `.p12` export.
- `MACOS_KEYCHAIN_PASSWORD`: optional temporary CI keychain password.
- `MACOS_APP_PROVISIONING_PROFILE_BASE64`: required base64 app provisioning
  profile for signed Release builds with CloudKit entitlements.
- `MACOS_WIDGET_PROVISIONING_PROFILE_BASE64`: required base64 widget extension
  provisioning profile for signed builds.
- `MACOS_REFRESH_AGENT_PROVISIONING_PROFILE_BASE64`: required base64 refresh
  agent provisioning profile for signed Release builds with CloudKit
  entitlements.

Treat the P12 and all three provisioning profiles as one Developer ID signing
set. Rotate them together. Before `xcodegen` or `xcodebuild` runs, packaging
requires every profile's `DeveloperCertificates` list to authorize the exact
fingerprint imported from the P12; after signing, packaging and runtime receipts
independently verify the certificate embedded in each signed bundle. Common-name
or `auto` selection is rejected when more than one matching signing certificate
is available.

To notarize, also configure:

- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_API_KEY_P8_BASE64`: base64-encoded App Store Connect API
  `.p8` key.

The workflow also supports the older Apple ID app-specific password path:

- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`

Or configure `APPLE_NOTARY_KEYCHAIN_PROFILE` if the CI keychain is provisioned
with a notarytool profile before packaging. Then run the workflow with
`notarize: true`.

## App Store Connect Build Upload

The `App Store Connect Build Upload` workflow is manually dispatched or called by
`Ship`. It requires App Store Connect API credentials, Apple Distribution
signing material, the Mac Installer Distribution certificate, and App Store
provisioning profiles for all three bundle identifiers:

- `com.shinycomputers.contextpanel`
- `com.shinycomputers.contextpanel.widget`
- `com.shinycomputers.contextpanel.refresh-agent`

The workflow calls `scripts/upload-app-store-connect-macos-app.sh`, which
generates the Xcode project, installs the supplied provisioning profiles,
archives with manual `Apple Distribution` signing, and exports with
`method = app-store-connect` and
`installerSigningCertificate = 3rd Party Mac Developer Installer`. The script
requires an explicit marketing version and rejects the closed `1.0` train before
archiving. Do not set `testFlightInternalTestingOnly`; internal-only builds are
valid for TestFlight but cannot be selected for App Store submission. Pass
`upload: false` when dispatching the workflow to export the `.pkg` without
uploading it.

The upload summary and artifact names include the App Store marketing version,
build number, target SHA, upload/export mode, and the fact that TestFlight beta
distribution is handled by the separate TestFlight workflow.

Every shipping Xcode target stamps a structured
`ContextPanelSurfaceManifest.json` before code signing. The macOS app also keeps
`ContextPanelBuildFingerprint.txt`, now sourced from the `macos.app` combined
fingerprint. Before export, the upload scripts verify the signed bundles against
the exact source manifest and write `ExpectedBuildManifest-<platform>.json` with
the executable hashes/UUIDs, signed-entitlement hashes, provisioning-profile
hashes, and per-surface fingerprints. The reviewed input mapping, evidence
classes, carry-forward rules, and CLI are documented in
[Signed Validation Fingerprints](signed-validation-fingerprints.md).

The macOS app, widget extension, refresh agent, iOS/iPadOS/visionOS companion
app and widget, Watch app and complication, and tvOS app and dynamic Top Shelf
extension can also emit session-gated, privacy-safe proof from their actual
process boundaries. Receipt collection is dormant by default and remains
distinct from shared-view and OS placement evidence. Device writers fail closed
without their App Group; existing entitled host apps now deliver sessions,
upload extension-local queues, and extract private CloudKit receipts. Production
schema deployment and signed physical-device proof remain required validation
steps. The schema, local queues, operator session lifecycle, privacy boundary,
and current limits are documented in
[Signed Validation Runtime Receipts](signed-validation-runtime-receipts.md).

The fingerprint contract hashes normalized target slices from `project.yml`,
not generated `ContextPanel.xcodeproj` output. XcodeGen formatting or object-ID
changes therefore cannot invalidate unrelated evidence. Unknown or unmapped
inputs produce an `unknown` embedded manifest during ordinary builds and fail
the commit/release gates before prior evidence can carry forward.

## TestFlight Beta Distribution

The `TestFlight Beta Distribution` workflow is manually dispatched or called by
`Ship`. It requires App Store Connect API credentials and consumes an already
uploaded build number. It waits until the build is visible and `VALID` in App
Store Connect, then assigns it to TestFlight beta groups. It reads each build's
`buildBetaDetail.internalBuildState` until it is `IN_BETA_TESTING` for internal
groups. External groups require confirmed assignment; Apple's beta review remains
separate and the readback labels external assignment accordingly. Groups with access to all builds need no explicit assignment; other
groups also require confirmed build membership after assignment. The availability
wait uses `--wait-timeout-seconds` (one hour by default), separately from the
processing wait, and `--poll-seconds` controls polling. If availability does not
arrive within the bound, the step fails and reports each group's observed state
and membership in the log and workflow summary. Dry runs check assignment needs
without waiting for or claiming availability.

Build numbers may be shared across Apple platforms. Distribution matches both
the requested marketing version and platform, and keeps polling when that build
number is visible only for a different platform.

By default the workflow includes internal TestFlight beta groups. Pass
`beta_groups` to add specific named groups as well, or disable
`include_internal_beta_groups` when only named groups should receive the build.
External TestFlight beta groups may still require Apple's beta review process;
keep external beta rollout expectations separate from internal dogfood testing.

For local operator use, the same script accepts App Store Connect environment
variables. Run the schema gate first (see "CloudKit Production Schema Gate"):

```sh
scripts/cloudkit-schema-gate.py check &&
  scripts/distribute-testflight-beta.py \
  --version 1.0.22 \
  --build-number 202606111944 \
  --platform MAC_OS
```

App Store Connect build upload is a shared prerequisite. TestFlight beta
distribution and App Store Review submission are sibling consumers of that
uploaded build; neither should secretly invoke the other.

## Companion TestFlight Validation

Use this path for companion device dogfood and CloudKit sync regression
validation. Issue #274 records the completed initial iOS/visionOS validation.
Normal `Ship` runs include every companion platform.

### Deliver current builds to all of Chris's devices

Merging companion code or running the unsigned compiler gate does not update a
companion device. One `Ship` run from protected `main` uploads and distributes
every package:

| Package  | Devices updated by that package                                     |
| -------- | ------------------------------------------------------------------- |
| iOS      | iPhone and iPad; the embedded Watch app and complication extension  |
| visionOS | Native Apple Vision Pro app and widget                              |
| tvOS     | Apple TV app and Top Shelf extension                                |

Apply [Before starting a release](#before-starting-a-release) first. Record the
source commit and finished-change list on the delivery issue, resolve existing
release holds, and choose a marketing version/build through the
[versioning flow](#normal-ship-workflow) and App Store version preflight.

Set these `Ship` inputs; the other inputs keep their defaults:

```text
version=<selected marketing version>
build_number=<selected build number, or blank for a UTC timestamp>
testflight_beta=true
include_internal_testflight_groups=true
release_issue=<the release's open plan issue number, for an App Store release>
```

These inputs include all existing internal groups; leave `testflight_beta_groups`
empty for that audience. For a narrower existing authorized group, set its name
and `include_internal_testflight_groups=false`. Confirm Chris belongs to the
selected audience; an internal group is not proof of membership, and
distribution does not install a build. Do not add testers or grant App Store
Connect access as an install workaround. Follow the
[schema publication gate](#cloudkit-production-schema-gate) and the existing
signed validation/evidence paths; these inputs do not bypass either gate.
Use the configured CI signing route rather than retrieving Apple credentials or
signing keys. A missing signing asset is an operator setup step, not permission
to copy a key into a task worktree.

After the run, record its source/version/build and each platform's upload,
processing and TestFlight distribution result on the delivery issue.
Export-only output and a successful upload alone do not establish that a build
is available to its tester. The iOS package supplies both phone and tablet;
there is no separate iPad or Watch upload.

Chris's device steps, only when needed:

1. Complete Apple ID/iCloud sign-in and Apple's verification prompts himself;
   no password, verification code or key belongs in the issue.
2. Open TestFlight on iPhone, iPad, Apple TV and Vision Pro with the existing
   tester Apple ID; install/update the recorded Context Panel version/build on
   **each** device. One iPhone install does not update the iPad.
3. Let the paired iPhone deliver the embedded Watch app (use the Watch app's
   install control if automatic installation is off). Confirm the new build on
   Watch, then restart Watch before routine complication review, following
   [the Watch restart rule](validation-authority.md#validation). Preserve
   existing complication placement.
4. If an explicitly selected local dogfood route requests device unlock, trust,
   Developer Mode or install approval, complete those prompts himself. They are
   not routine TestFlight prerequisites. The existing Vision Pro dogfood helper
   uses Development CloudKit and does not replace Production TestFlight proof.
5. Read **About** in the iPhone/iPad/Vision Pro or TV app, or scroll to **About**
   on Watch, and record the installed version/build for every device. Check the
   new account layout separately from last-updated/sync state. An old build is a
   delivery gap; a current build with old readings needs sync diagnosis.

Keep device installation and exact-build physical acceptance open on the owning
issue until observed. A CI summary, simulator capture or another device's
installed version cannot close those steps.

### tvOS Release Lane

The `ContextPanelTV` scheme is a standalone read-only tvOS app. The release path
archives it for `generic/platform=tvOS`, validates a tvOS App Store profile for
bundle ID `com.shinycomputers.contextpanel` and CloudKit container
`iCloud.com.shinycomputers.contextpanel`, uploads it as App Store Connect
platform `TV_OS`, and can assign the processed build to TestFlight groups.

The tvOS app intentionally does not embed the iOS/visionOS widget or watchOS
targets and does not request iCloud Documents or ubiquity entitlements. It does
share `group.com.shinycomputers.contextpanel` with its Top Shelf extension and
runs both targets as the current Apple TV user. App Store Connect requires
`aps-environment` when the tvOS binary declares CloudKit, so Release uses the
production APNs environment for best-effort background sync. Debug signs the
tvOS app for Development CloudKit and Release signs it for Production; the
archive gate verifies the signed environment before export.

The tvOS target compiles layered small/App Store icons plus required standard and
wide Top Shelf artwork from
`Resources/TVAssets.xcassets/App Icon & Top Shelf Image.brandassets`. Both the CI
archive gate and signed upload script require the compiled `Assets.car`, the
`App Icon - Small` primary-icon declaration, and both generated
`TVTopShelfImage` keys. They also require the compiled Top Shelf extension to
declare `arm64` in `UIRequiredDeviceCapabilities`; App Store Connect rejects the
64-bit extension as an invalid bundle without that declaration. The static brand
artwork remains the fallback, while the embedded
`ContextPanelTVTopShelfExtension` provides privacy-filtered dynamic provider
runway from the shared App Group without network access.

The signed tvOS export-only canary is:

```sh
scripts/upload-app-store-connect-companion-app.sh \
  --platform tvos \
  --version <active-tvos-app-store-version> \
  --build-number <yyyymmddHHMM> \
  --export-only
```

Upload the approved tvOS screenshots with the `tvos` screenshot set; the
uploader maps them to App Store Connect display type `APP_APPLE_TV` (see the
[screenshot matrix](../Resources/AppStore/Screenshots/screenshot-matrix.md)). The first tvOS App Store version already has its approved
description and screenshots; verify the live App Store Connect record before
editing or submitting a later train.

### visionOS Release Lane

For a fresh visionOS update, `scripts/validate-companion-builds.sh visionos`
remains only the unsigned compiler gate. Release evidence also requires a signed
upload from `main`, the live Production CloudKit schema gate, TestFlight
distribution, and a physical Vision Pro smoke check of launch, synced data,
stale/degraded presentation, and widget rendering when that surface changed.

The required visionOS app icon asset should live under:

```text
Resources/Assets.xcassets/AppIcon.solidimagestack/
  Contents.json
  Back.solidimagestacklayer/
    Contents.json
    Content.imageset/Contents.json
  Middle.solidimagestacklayer/
    Contents.json
    Content.imageset/Contents.json
  Front.solidimagestacklayer/
    Contents.json
    Content.imageset/Contents.json
```

Use two or three `.solidimagestacklayer` entries. The background layer must be
opaque, and each layer image should be a full-bleed square image sized for the
visionOS App Store icon. The upload script rejects a root-only placeholder icon
stack so `--platform visionos` cannot become accidental signed release evidence.

### Required Signing Material

The companion upload path requires the same App Store Connect API key used by
the Mac upload path plus companion-specific Apple Distribution signing assets:

- `MACOS_APP_STORE_DISTRIBUTION_CERTIFICATE_P12`
- `MACOS_APP_STORE_CERTIFICATE_PASSWORD` or `MACOS_CERTIFICATE_PASSWORD`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_API_KEY_P8_BASE64`
- `APPLE_TEAM_ID`
- `COMPANION_APP_STORE_APP_PROVISIONING_PROFILE_BASE64`
- `COMPANION_APP_STORE_WIDGET_PROVISIONING_PROFILE_BASE64`
- `COMPANION_APP_STORE_WATCH_PROVISIONING_PROFILE_BASE64` for iOS companion
  uploads that embed the watchOS companion app
- `COMPANION_APP_STORE_WATCH_WIDGET_PROVISIONING_PROFILE_BASE64` for iOS
  companion uploads that embed the watchOS complication extension
- `COMPANION_APP_STORE_TV_PROVISIONING_PROFILE_BASE64` for the standalone tvOS
  app
- `COMPANION_APP_STORE_TV_TOP_SHELF_PROVISIONING_PROFILE_BASE64` for bundle ID
  `com.shinycomputers.contextpanel.topshelf`

The companion app profile must authorize:

- bundle ID `com.shinycomputers.contextpanel`
- App Group `group.com.shinycomputers.contextpanel`
- iCloud container `iCloud.com.shinycomputers.contextpanel`
- Production CloudKit environment
- iCloud Documents, CloudKit, ubiquity container access, and APNs background
  notifications
- the selected platform: iOS for iPhone/iPad, or visionOS/xrOS for visionOS

The companion widget profile must authorize bundle ID
`com.shinycomputers.contextpanel.widget`, App Group
`group.com.shinycomputers.contextpanel`, CloudKit container
`iCloud.com.shinycomputers.contextpanel`, the Production CloudKit environment,
and the selected platform. It should not authorize iCloud Documents, ubiquity,
or APNs. The companion widget timeline reads Production CloudKit directly with
a bounded deadline and uses the app-group mirror as its last-good fallback.

For iOS companion uploads, the watch app profile must authorize bundle ID
`com.shinycomputers.contextpanel.watch`, App Group
`group.com.shinycomputers.contextpanel`, and the Context Panel CloudKit container.
The watch complication profile must authorize bundle ID
`com.shinycomputers.contextpanel.watch.widget`, the same App Group, and the same
CloudKit container. The Watch app and complication both read Production CloudKit
directly and coordinate one Watch-local App Group cache as their last-good value.
Debug targets use Development CloudKit entitlements, while Release targets use
the dedicated Watch App Store entitlement files that require Production.
App Store Connect may report `iOS` platform metadata for the embedded watch
profiles because the watch app and complication extension are exported as part
of the iOS companion archive. The watch app is embedded only in the iOS companion
package; native visionOS companion builds deliberately exclude watchOS content.
The upload script stops before export if either archived Watch target lacks the
shared App Group or its required Production CloudKit container and entitlements.

For signed iOS companion archives, the upload script also emits a generic
`WatchArchiveReceipt-iOS.txt` after validating the nested iOS app, Watch app, and
Watch widget identities, marketing-version/build parity, code signatures,
signed entitlements, executable SHA-256 fingerprints, and dSYM UUID coverage.
It also emits `ExpectedBuildManifest-ios.json`, which binds those signed
artifacts to the iPhone, iPad, Watch app, and complication surface fingerprints.
The companion upload workflow retains both receipts and the signed `.xcarchive`
as release evidence.

For physical TestFlight validation, exercise both a cold complication load and a
cached degraded load. A cold load must render current Production CloudKit data
without first launching the Watch app. After either the Watch app or complication
refreshes, the other process must read the same account values from the shared
cache. Temporarily removing network access should preserve those last-good
numbers as stale rather than returning setup-only or silently healthy output.

The tvOS app profile is separate from the iOS/visionOS companion app profile
even though it uses the same bundle ID. It must support `tvOS`, authorize
CloudKit for `iCloud.com.shinycomputers.contextpanel`, carry production APNs,
authorize App Group `group.com.shinycomputers.contextpanel`, and include
`runs-as-current-user-with-user-independent-keychain`. It does not need the
iOS/visionOS-only iCloud Documents, ubiquity, widget, or watch entitlements.

The tvOS Top Shelf profile must support bundle ID
`com.shinycomputers.contextpanel.topshelf`, the tvOS platform, the same App
Group, and the same current-user capability. The extension must not carry
CloudKit or APNs entitlements.

Do not remove older App IDs, profiles, or profile secrets while validating the
new companion path. Keep them available until a signed device/TestFlight install
has proven that Mac publish, CloudKit delivery, companion app load, and
companion widget rendering all work.

### CloudKit Production Schema Gate

Chris chose this design on [#904](https://github.com/cbusillo/context-panel/issues/904):
check Production only when the committed schema changes, from CI, with the
management token held as a GitHub secret.

The companion TestFlight and App Store builds use the Production CloudKit
environment for `iCloud.com.shinycomputers.contextpanel`. Private database
records still depend on the container's Production schema, so a production-
entitled Mac build cannot rely on runtime schema creation.

Before companion TestFlight distribution, App Store Review, or signed runtime
receipt relay, validate that Production contains the companion snapshot and
runtime-evidence contracts in `CloudKit/companion-sync.schema.ckdb`.

Run the offline repo contract check before packaging:

```sh
scripts/validate-cloudkit-companion-schema.sh
```

The checked-in `CloudKit/companion-sync.schema.ckdb` file is the exact additive
schema candidate. It preserves the existing companion and `Users` definitions,
adds the two runtime record types, includes the required range index, and omits
public-database grants for runtime evidence. Do not reconstruct the candidate by
hand in CloudKit Console.

Every build also checks the app against that contract without credentials:
Swift tests build the companion snapshot and runtime records the app writes
and compare each record's type, name, fields and value types with
`CloudKit/companion-sync.schema.json`, and the routine Python tests run the
offline check above.

#### When Production is checked

Each publication step runs `scripts/cloudkit-schema-gate.py check` before it
publishes: GitHub Release publication, Mac and companion uploads in upload
mode, TestFlight distribution outside dry runs, and App Store Review live
operations. Export-only, artifact-only, dry-run and cancel-only paths skip it.
The gate compares `CloudKit/` with the newest `vMAJOR.MINOR.PATCH` release tag
reachable from the commit being released. It trusts that tag only when its
GitHub Release was published by `github-actions[bot]`, because the release
workflow publishes only after this gate; a hand-made tag or release does not
count. (A tag ruleset cannot do this here: personal-account repositories cannot
exempt GitHub Actions from one.)

- unchanged since a trusted tag: no live check
- changed, no reachable tag, or a tag whose release is missing or published by
  anyone else: the live validator must pass against Production (`scripts/validate-cloudkit-companion-schema.sh --live
  --environment production`)
- the export fails, the token is missing, Production does not match, or
  history cannot be read: the step refuses and nothing is published

Production accepts only additive schema deployments, so a contract verified
once stays deployed. In CI the token comes from `CLOUDKIT_MANAGEMENT_TOKEN` in
the `release` environment, the single release secret store, limited to Branch
`main` and checked by every release run's guard. Only the gate step receives
it. Runtime receipt sync runs the same gate on the operator Mac (see
[Signed Validation Runtime Receipts](signed-validation-runtime-receipts.md))
and does not pass the token to the signed agent. For a live release command
run locally, run `scripts/cloudkit-schema-gate.py check` first; it uses the
token `cktool` saved in the Keychain.

The live gate uses Apple's `cktool`, not the App Store Connect API key. `cktool`
needs a CloudKit management token. Apple documents that management tokens are
generated from CloudKit Console settings, are scoped to the developer team and
user, default to a one-year lifetime, and can be revoked from CloudKit Dashboard
settings. `cktool` can then save the token securely in the Mac Keychain.

The schema gate does not promote a new `CKSubscription` definition. Runtime
session and receipt record types intentionally have no subscription, so uploads,
deletions, and extraction cannot wake the companion snapshot loop. Context
Panel's Production companion contract continues to use subscription ID
`companion-sync-updates` with a query for the fixed legacy `current` wake record.
The versioned `current-v2` record remains authoritative, while clients reload and
merge both records after a wake notification. Keep any existing
`companion-sync-updates-v2` or `companion-sync-updates-v3` subscriptions during
the internal rolling-upgrade bridge; older builds may still rely on them while
replacement builds are installing. Do not deploy the abandoned `v3` definition
to Production while this compatibility contract is active. CloudKit
rejects subscription IDs or predicates introduced for the first time by a
Production runtime. Before changing that contract, create the new subscription
in Development, deploy the resulting CloudKit schema changes to Production, and
physically verify registration from the signed TestFlight build. Do not ship a
new subscription ID or predicate based only on the exported field schema passing.

When replacing a build that attempted the abandoned `v3` subscription, upload
new builds for the Mac publisher and every companion platform under the same
editable marketing version. Install and validate the Mac publisher first so it
writes both `current-v2` and the `current` wake mirror, then update iOS/watchOS,
visionOS, and tvOS. This order keeps both subscription generations live during
the internal rollout. Accurate per-account stale-state presentation requires the
replacement companions; older clients consume the mirror only as a compatibility
bridge.

Relevant Apple references:

- <https://developer.apple.com/icloud/ck-tool/>
- <https://developer.apple.com/icloud/cloudkit/automating/>
- <https://developer.apple.com/documentation/cloudkit/cksubscription>

To get and save the token on the local operator machine:

1. Open CloudKit Console for the app's Apple Developer team.
2. In the user/account Settings area, create a CloudKit management token.
3. Copy the token when CloudKit Console shows it; Apple does not show it again.
4. Save it to Keychain with `cktool`:

```sh
xcrun cktool save-token --type management --method keychain --force
```

1. Verify that `cktool` can use the saved token without printing it:

```sh
xcrun cktool get-teams
```

To give CI the token, the owner opens **Settings → Environments → release →
Environment secrets → Add environment secret**, names it
`CLOUDKIT_MANAGEMENT_TOKEN`, and pastes the token. Do not add it as a
repository secret or to another environment. Replace it there when it is
rotated or expires.

If Keychain storage is unavailable, provide the token only to the command
process with `CLOUDKIT_MANAGEMENT_TOKEN`; do not write the token into tracked
files, shell history, GitHub issues, PRs, agent summaries, or release notes.

Both upload helpers have one test-only input,
`CONTEXT_PANEL_UPLOAD_FIXTURE_TOOLS_DIR`. The Mac helper replaces `xcodebuild`;
the companion helper also replaces `codesign` and `xcrun`, so archive checks can
be tested without building. Never set it in a workflow or an operator shell.
Each helper refuses to start an upload while it is set, and an export prints a warning
that the result is not a release artifact.

The Mac archive/resume fixture command is
`qualityGate.validate.macOSUploadFixtureTests` in [.github/github.json](../.github/github.json).
They use fake profiles and credentials in isolated storage, with fake profile
decoding, project generation, fingerprint generation and expected-build collection.
They exercise `--export-only` with `--archive-only` or `--skip-archive`, including
version/build and source mismatch refusals and missing fresh package output.
They do not qualify signing, real archives, or live uploads.

If the live gate reports a missing runtime record type or index, re-export both
environments and require Production and Development to contain no unrelated
schema drift. Validate and import the checked-in candidate into Development:

```sh
xcrun cktool validate-schema \
  --team-id "${APPLE_TEAM_ID:-MM5YXC7T6E}" \
  --container-id iCloud.com.shinycomputers.contextpanel \
  --environment development \
  --file CloudKit/companion-sync.schema.ckdb

xcrun cktool import-schema \
  --team-id "${APPLE_TEAM_ID:-MM5YXC7T6E}" \
  --container-id iCloud.com.shinycomputers.contextpanel \
  --environment development \
  --validate \
  --file CloudKit/companion-sync.schema.ckdb
```

Re-export Development, run the live Development gate, and canary session
publish/load/clear, receipt lookup, and expired-receipt pruning before using
CloudKit Console's **Deploy Schema Changes** action. Do not import directly into
Production and never use `cktool reset-schema`; reset deletes Development data.
After deployment, re-export Production and require the live Production gate to
pass before re-running Mac publish, receipt relay, and companion TestFlight
validation.

A missing runtime record type is `unknown` evidence, not permission to fall back
to the companion snapshot record. If Production already contains an incompatible
field type, do not try to patch the existing field in place; add a
forward-compatible record type such as `CompanionSyncDocumentV2`, or new field
names for the affected runtime record, and update the app constants and schema
contract together.

### Export-Only Canary

Before uploading a companion build, run the companion upload workflow with
`upload=false` or run the script locally with real profiles and API credentials:

```sh
scripts/upload-app-store-connect-companion-app.sh \
  --platform ios \
  --version <active-companion-app-store-version> \
  --build-number <yyyymmddHHMM> \
  --export-only
```

That canary should archive `ContextPanelCompanion`, embed
`ContextPanelCompanionWidgetExtension`, validate both provisioning profiles for
the selected platform and App Group, validate the companion app profile for
iCloud Documents, CloudKit, ubiquity, and production APNs entitlements, then
export a signed IPA under `.build/app-store-connect-companion/`.

The native visionOS packaging requirements proven by #230 remain mandatory. A
passing generic no-sign visionOS build is not enough to run this as release
evidence. The visionOS profiles must support `visionOS` or `xrOS`. The upload
script also blocks `--platform visionos` until a complete
`Resources/Assets.xcassets/AppIcon.solidimagestack` with solid image stack
layers exists, so a missing or placeholder layered visionOS icon cannot become
accidental signed release evidence.

Use the signed canary shape validated by #231:

```sh
scripts/upload-app-store-connect-companion-app.sh \
  --platform visionos \
  --version <active-companion-app-store-version> \
  --build-number <yyyymmddHHMM> \
  --export-only
```

The archive must be followed by a signed Apple Vision Pro device smoke test
before calling it TestFlight or release validated. A visionOS simulator run can
be useful for pre-release UI smoke, but it does not validate TestFlight
installability, App Store provisioning, or physical device runtime behavior.

The unsigned companion validation helper watches for Xcode's terminal build or
archive marker and releases a wedged Xcode process after that marker appears.
It streams the build log live, gives successful builds a short natural-exit
grace period, and then terminates the validation process group plus its known
descendants. Cleanup escalates from `SIGTERM` to `SIGKILL` on a bounded deadline
so a wedged process cannot also wedge the validation wrapper. A pre-terminal
Xcode service stall with no output for five minutes receives one retry with
isolated temporary DerivedData; ordinary compiler, packaging, and archive
validation failures are never retried. On success, failure, timeout, or handled
interruption, the validator moves only generated Context Panel app and extension
bundle roots out of `companion-build-validation` into a timestamped same-volume
quarantine. Nested Watch content moves with its parent app, symlinked products
are moved without following their targets, and every quarantined `.app` and
`.appex` suffix is neutralized so runtime discovery cannot treat the quarantine
as another installed build. Signed bundle material causes cleanup to fail closed
rather than moving release artifacts. The original validation failure remains
the command's exit status if cleanup also fails.

Quarantine retention is an explicit operator command; builds do not delete it.
Keep seven days of unsigned generated bundles for diagnosis. Preview an exact
root, then repeat with `--apply` to delete eligible entries:

```sh
scripts/context-panel-companion-cache.sh prune \
  --root <absolute-.build-or-derived-data/companion-build-validation-root>
scripts/context-panel-companion-cache.sh prune \
  --root <same-root> --apply
```

Use `--older-than-days N` to retain a longer window (minimum one day). Only
timestamped entries in that root's quarantine are eligible, and both their
creation stamp and all content modification/change times must be older than
the window. Signed or non-neutralized bundles, hard-linked files, unrecognized
content outside quarantined bundles, recent writes, and entry symlinks are
preserved. Empty failed entries and ordinary Finder `.DS_Store` files can age
out with the entry. Directory
opens and deletion never follow symlinks; links within recognized bundle trees
are unlinked without opening their targets. Symlinked ancestry or quarantine
roots and inventory errors fail closed. No compiler caches, active DerivedData,
manifests, receipts, installed apps, or production storage are deleted. Run this
with the cache idle; a filesystem error can leave a partially removed eligible
entry. `prune=PARTIAL` names that timestamped entry without printing host paths;
inspect it before retrying. `prune=FAILED` reports an inventory failure. Both
include the count of entries already removed: a run is not transactional.
Ctrl-C stops promptly with `prune=INTERRUPTED`, an unknown removal count and a
possible partial removal; inspect the quarantine before retrying. Abrupt process
termination can also leave partial work.

### Local Apple Vision Pro Dogfood

Use the local dogfood helper when the goal is to install the Debug companion app
on a paired Apple Vision Pro before TestFlight:

```sh
scripts/dogfood-visionos-companion.sh
```

The helper builds `ContextPanelCompanion` for visionOS with Debug automatic
development signing, installs the app with `devicectl`, then launches bundle ID
`com.shinycomputers.contextpanel`. It requires a paired physical visionOS device
whose CoreDevice tunnel is available; if the Vision Pro is asleep, locked, or
offline, the helper stops before install and asks the operator to wake/unlock the
headset.

For a signing-only check that does not require a paired headset or available
CoreDevice tunnel, run:

```sh
scripts/dogfood-visionos-companion.sh --build-only
```

This path is for local dogfood only. It does not satisfy the `--platform
visionos` release-upload guard, App Store Connect/TestFlight upload, final
visionOS layered icon, or App Review metadata requirements.

### Upload And Distribution

The lower-level companion upload workflow is:

```text
App Store Connect Companion Build Upload
```

Use inputs:

- `version`: the App Store marketing version.
- `build_number`: optional; blank uses a UTC timestamp.
- `platform`: `ios`, `visionos`, or `tvos`.
- `upload`: `true` to upload, `false` for export-only.

Upload mode may not emit a local IPA because Xcode can upload the signed archive
directly. Export-only mode must emit a local IPA. In either mode, retain the
signed `.xcarchive`; for iOS also retain `WatchArchiveReceipt-iOS.txt` and the
export/upload output as workflow artifacts.

After a successful upload, distribute that build with `TestFlight Beta
Distribution` using:

- `platform=IOS` for iPhone/iPad companion builds.
- `platform=VISION_OS` for visionOS companion builds.
- `platform=TV_OS` for tvOS builds.
- the same `version` and resolved `build_number` from the upload summary.

`Ship` runs this upload and distribution for all three companion platforms
alongside the Mac build. Use the lower-level workflows directly only to recover
one platform at the same version and build.

Completed issues #168, #230, and #231 record the initial visionOS packaging,
profile, icon, metadata, App Store Connect, and signed-device proof. The signed
tvOS lane is recorded by #379; both tvOS profile secrets remain required. The signed candidate includes Couch Mode,
the dynamic Top Shelf extension, and upgrade cleanup for the retired provider
badge. A tvOS submission needs physical Apple TV proof only when the release
gate's scope, the release comparison plus any active runtime regression
watchlist entry, requires runtime or placement evidence for a tvOS surface.
Every submission still needs screenshot, metadata, privacy, and reviewer
evidence, including any demo video App Review asks for.

### Signed Device Smoke Test

Before treating a companion TestFlight build as release evidence, validate this
sequence from signed runtimes.

New archive collection emits expected-build schema v2. Retained sealed
expected-build schema v1 manifests remain replay-compatible, but unsealed
intermediate artifact-evidence JSON from the older schema must be regenerated
from the archive before sealing; do not carry it across release-tooling updates.

First compare the prior approved full source manifest with the candidate source
manifest for the intended train:

```sh
scripts/context-panel-surface-manifest.py compare \
  --previous <previous-source-manifest.json> \
  --current <candidate-source-manifest.json> \
  --previous-expected-build-manifest <previous-platform-1.json> \
  --previous-expected-build-manifest <previous-platform-2.json> \
  --current-expected-build-manifest <candidate-platform-1.json> \
  --current-expected-build-manifest <candidate-platform-2.json> \
  --train <beta|rc|release> \
  --output <comparison.json>
```

Repeat each expected-build option for every archive layout that covers the
shipping surface manifest. Partial layout coverage is recorded as missing
artifact evidence and escalates fail-closed; it is useful for diagnostics but
is not a complete signed-train comparison.

### Release Evidence Carry-Forward Gate

Use the full source-manifest comparison without filtering or rewriting its
`requiredSurfaces`. After the coordinator final report and sealed expected-build
manifests are available, produce the privacy-safe release evidence ledger:

```sh
scripts/context-panel-release-gate.py enforce \
  --train <beta|rc> \
  --comparison <comparison.json> \
  --validation-report <final-report.json> \
  --expected-build-manifest <ExpectedBuildManifest-platform.json> \
  --previous-ledger <previous-approved-lineage.json> \
  --host-os-evidence <host-os-evidence.json> \
  --output <release-evidence.json> \
  --lineage-output <release-evidence-lineage.json>
```

Supply the complete sealed expected-build manifest set for every shipping
surface; a comparison or manifest set that omits a shipping surface fails closed. Omit the
previous lineage bundle when no earlier approval exists. A baseline released
before ledger lineage existed (comparison previous evidence `legacy-incomplete`,
such as 1.0.60) has no lineage to supply its build manifests; the gate accepts
that comparison without one only while it fails closed with nothing eligible
to carry forward, so every surface proves all of its evidence fresh. The
ledger output is
the privacy-safe report; the separate lineage output contains the authoritative
generation inputs needed to replay that ledger before it can be reused.
Placement carry-forward always
requires matching placement fingerprint, a current exact-build runtime receipt,
and compatible current host OS evidence. Major or minor host OS changes fail
closed. Patch changes also invalidate compositor-sensitive surfaces listed in
`Config/ContextPanelReleaseEvidencePolicy.json`. Evidence expires after the
policy's bounded retention and cannot silently outlive the source ledger it was
carried from. The host OS evidence object must bind its `target` and
`currentManifestID` to the candidate and bind each surface's bounded `hostOS`
value to a `runtimeReceiptID` present in the current coordinator report. Future,
expired, unrelated-build, or unrelated-receipt observations fail closed.

Release trains additionally require `--selected-rc-ledger` with the replayable
lineage bundle for the exact same version, build, and manifest. Raw or
self-authored ledger JSON is not accepted. Prior and selected-RC lineage is
replayed transitively with a fixed depth limit before any evidence can be
carried. A changed selected build must return to RC
validation. Release enforcement uses the same inputs:

```sh
scripts/context-panel-release-gate.py enforce \
  --train release \
  --comparison <comparison.json> \
  --validation-report <final-report.json> \
  --expected-build-manifest <ExpectedBuildManifest-platform.json> \
  --selected-rc-ledger <approved-rc-lineage.json> \
  --host-os-evidence <host-os-evidence.json> \
  [--historical-policy-archive Config/ContextPanelHistoricalPolicyArchive.json] \
  --output <release-evidence.json> \
  --lineage-output <release-evidence-lineage.json>
```

Historical lineage is digest-bound to the release and surface policies that
generated each retained ledger. Current train comparison, required scope,
watchlist expansion, carry-forward admission, expiry, and output digests always
use the currently configured `Config/ContextPanelReleaseEvidencePolicy.json` and
`Config/ContextPanelSurfacePolicy.json`. Previous-ledger, selected-RC, and
any retained embedded shadow subtrees instead resolve their `policyDigest` and
`surfacePolicyDigest` through an explicit historical policy archive, validate
those preimages, verify their canonical JSON digests, and reconstruct the old
ledger bytes exactly. Missing, malformed, mismatched, duplicate, or unused
archive entries fail closed. Pre-watchlist schema-v1 release policies are valid
only during historical reconstruction; an absent watchlist is interpreted as an
empty watchlist without modifying the historical payload or its digest.

The committed public-safe archive
`Config/ContextPanelHistoricalPolicyArchive.json` contains only bounded policy
preimages needed to replay retained public ledgers, beginning with 1.0.60. Do
not hand-edit the archive or retained lineage JSON. Recover policy preimages
from version-controlled release sources, canonicalize with the gate's JSON
digest, add only entries that are required by retained lineage, and keep private
receipts, device data, local checkout paths, screenshots, and operator secrets
out of the archive. The `--historical-policy-archive` option is optional because
many trains only reference current policies, but any supplied unused entry is a
validation failure.

The App Store submission workflow accepts the ledger separately from the
coordinator report. Every live build attachment or submission requires the
`release` evidence tier and release-evidence report in both `shadow` and
`enforce` mode, plus the exact selected-RC lineage bundle, the full
comparison and a JSON array containing every sealed expected-build manifest
needed by its required scope. The submission workflow defaults to
`release_evidence_mode=enforce`; both modes bind the current configured policy
and surface-policy digests. Enforce mode requires an approved ledger; missing,
expired, host-incompatible, policy-mismatched, scope-mismatched, or mixed-build evidence
blocks submission. Dry runs, cancel-only operations, and prepare-only operations
without a build remain exempt. The ledger binds the canonical configured policy,
full comparison, expected-build identity set, and exact coordinator report;
submission independently recomputes every binding. When historical lineage needs
non-current policy preimages, include the same archive used by the release gate
in the [submission evidence bundle](#submission-evidence-bundle); the workflow
passes it to the submission validator as
`--release-evidence-historical-policy-archive`.

Validate a ledger outside the submission workflow with the same authoritative
inputs:

```sh
scripts/validate-release-evidence-report.py \
  --report <release-evidence.json> \
  --validation-report <final-report.json> \
  --comparison <comparison.json> \
  --expected-build-manifest <ExpectedBuildManifest-platform.json> \
  --policy Config/ContextPanelReleaseEvidencePolicy.json \
  --surface-policy Config/ContextPanelSurfacePolicy.json \
  [--historical-policy-archive Config/ContextPanelHistoricalPolicyArchive.json] \
  --version <version> \
  --build-number <build-number> \
  --train <beta|rc>
```

Release validation uses the same command with `--train release` and the
mandatory `--selected-rc-ledger <approved-rc-lineage.json>` argument.

Add `--enforce` when validating an enforcement ledger. Repeat
`--expected-build-manifest` until every shipping surface is covered, including
surfaces that are unchanged and do not require fresh evidence. Supply the same
optional replayable prior lineage and evidence artifacts used to generate the
ledger with `--previous-ledger` and `--host-os-evidence`.
Supply `--historical-policy-archive` only when a retained lineage subtree binds
non-current release or surface policy digests. The selected-RC lineage is
mandatory for release validation. Final validation
reconstructs the complete ledger at its
original `generatedAt`; relabeling evidence sources or omitting the selected RC
therefore fails even when all public digests are recomputed.

For a beta with `requiresRuntimeSession=false`, do not open devices or create a
runtime-receipt session; automated shared-view evidence is sufficient for that
slice. The coordinator can still hold the shared-view approval ledger with an
empty runtime surface scope. Create or recover the durable coordinator session
for the exact train before anyone begins visual review:

```sh
scripts/context-panel-validation.py start-session \
  --version <marketing-version> \
  --build-number <coordinated-build-number> \
  --surface-comparison <comparison.json> \
  --visual-review-requirements <visual-review-requirements.json> \
  --expected-build-manifest <ExpectedBuildManifest-macos.json> \
  --expected-build-manifest <ExpectedBuildManifest-ios.json> \
  --expected-build-manifest <ExpectedBuildManifest-visionos.json> \
  --expected-build-manifest <ExpectedBuildManifest-tvos.json>
```

When comparison and visual requirements are supplied, the coordinator derives
the runtime scope from `requiredSurfaces.actual-runtime`; an explicit repeated
`--surface` list must match that set exactly. Without those files, omitting
`--surface` requests every shipping surface; release automation uses the
comparison output instead. A matching existing session is recovered
unchanged; replacing it requires `--replace`, and a different active target is
rejected by both lifecycle and status commands.
Visual review requirements cover only each surface's `freshEvidence` visual
classes. Omit carry-forward-eligible shared-view or placement checks from the
current coordinator plan; the release gate must resolve those classes from the
validated prior lineage instead of creating redundant human actions. If that
lineage is unavailable or expired, an operator may deliberately include a
carry-forward-eligible requirement to collect fresh fallback evidence.
Status continues to show collected out-of-scope evidence for diagnostics, but
only requested surfaces can block the slice or produce operator actions.
Pass each sealed `ExpectedBuildManifest-<platform>.json` needed to cover every
runtime or visual surface required by the comparison. More manifests can be
attached later by `status` or `sync-runtime-evidence`; an existing surface
identity can never be replaced by a conflicting manifest.

The schema-versioned coordinator state lives under the canonical App Group at
`Context Panel/Validation/Coordinator`, separate from signed runtime session and
receipt files. Session writes are lock-protected, atomic, mode `0600`, bounded
by retention, and contain no device identifiers, account data, credentials, raw
provider payloads, App Store Connect object IDs, or private paths. Tests may set
`CONTEXT_PANEL_VALIDATION_STATE_ROOT`; release operators should use the default.
Compatibility-only Watch attestations recorded before a session exists remain
in the older local store until the first matching session migrates them.
Normal status reads enforce terminal retention and remove expired coordinator
documents without touching runtime receipts or App Group relay queues.
Runtime receipt summaries use an additive schema-v1 sidecar under
`Coordinator/Runtime Evidence`, keyed by the coordinator session ID and pruned
with the parent session. The lifecycle document remains schema v1 and is never
silently rewritten to add receipt fields. The sidecar contains expected public
build identity, receipt IDs, ordering metadata, closed outcomes, and diagnostic
codes only; it does not persist raw exports or receipt documents.
Operator queue and visual review state use further schema-v1 sidecars, pruned
with the parent session; see
[Signed Validation Operator Flow](signed-validation-operator-flow.md#persistence).

Signed host apps also contain the fixture-isolated shared widget gallery
documented in [Signed Validation Galleries](signed-validation-galleries.md).
Normal product UI does not expose gallery navigation; signed-validation
operators use the allowlisted routes and Watch launch argument documented there.
Gallery and deterministic render outputs are shared-view evidence. They can
satisfy render-only beta requirements only after a matching approval is
recorded: Chris's, or a
[reference approval](validation-authority.md#reference-images). They do not
satisfy exact-build runtime receipts or OS-composited placement approval.

After opening the bounded runtime receipt window described in
[Signed Validation Runtime Receipts](signed-validation-runtime-receipts.md),
relay through the existing signed host and reconcile the sanitized export:

```sh
scripts/context-panel-validation.py sync-runtime-evidence \
  --version <marketing-version> \
  --build-number <coordinated-build-number>
```

This explicit command invokes the existing runtime-session `sync`, `status`,
and exact-session `export` contracts. It does not contain a Python CloudKit
client, mutate CloudKit schema, install a runtime, or add extension
entitlements. Raw signed-host messages and subprocess errors are not persisted.

Then collect coordinator status so waiting and access states are classified
before anyone begins opening devices:

```sh
scripts/context-panel-validation.py status \
  --version <marketing-version> \
  --build-number <coordinated-build-number>
```

The coordinator reads App Store Connect through GET-only requests, runs the
canonical Mac Production receipt, and inspects physical-device reachability and
installed app versions through CoreDevice list/info commands. When expected
build evidence is attached, status also reads the existing runtime-session
`status` and exact-session `export` contracts without invoking relay `sync`.
It never installs,
launches app or device UI, wakes, reboots, captures, resets, submits, cancels, or
changes App Store Connect state. Status may persist only local coordinator
lifecycle changes such as deadline expiry and privacy-safe runtime evidence
summaries. The canonical receipt may execute the
refresh agent's privacy-safe bookmark-access, provider-credential-presence, and
webhook-credential-presence summaries. Locked, sleeping, unreachable,
processing, and unavailable states are reported as waiting or unknown rather
than application failures.

Pause and resume coordinator timers without deleting runtime evidence or App
Group relay queues:

```sh
scripts/context-panel-validation.py pause-session \
  --version <marketing-version> \
  --build-number <coordinated-build-number> \
  --reason operator-unavailable

scripts/context-panel-validation.py resume-session \
  --version <marketing-version> \
  --build-number <coordinated-build-number>
```

Close the workflow session without deleting collected evidence:

```sh
scripts/context-panel-validation.py stop-session \
  --version <marketing-version> \
  --build-number <coordinated-build-number>
```

Runtime proof requires exact version/build, source manifest and contract,
surface fingerprints, bundle and artifact identity, and a loaded executable UUID
contained in the sealed archive evidence. A host-app receipt never proves its
widget, Watch complication, or Top Shelf extension. Duplicate exports are
de-duplicated by receipt ID, process ordering is retained, and newer build
evidence supersedes rather than mixes with the target. Missing receipts remain
waiting while the bounded runtime window is active; expired silence, stale
extensions, malformed exports, and relay problems become unknown or diagnostic,
not product failures. Companion CloudKit content and visual approval remain
separate evidence classes for later slices.

Status exit codes, queue timing, notification decisions and deferrals are
defined in [Signed Validation Operator Flow](signed-validation-operator-flow.md).
`sync-runtime-evidence` follows the same non-failure waiting rule: it exits `0`
for an active bounded receipt wait or proven runtime slice, `20` when newer
evidence supersedes the target, and `30` for an unknown/diagnostic result.

Live App Store build attachment and review submission require the exact-build
[final report](signed-validation-operator-flow.md#final-report). Generate it
only after the coordinator reaches `complete_for_slice` with every required
runtime surface proven, no active deferrals, no pending operator
actions, and no runtime diagnostics:

```sh
scripts/context-panel-validation.py final-report \
  --version <marketing-version> \
  --build-number <coordinated-build-number> \
  --json > .build/validation-report.json
```

The App Store submit helper accepts the file with `--validation-report`. The
GitHub workflow receives it inside the
[submission evidence bundle](#submission-evidence-bundle). The report is
validated before App Store
Connect credentials are used. Dry runs, cancel-only recovery, and prepare-only
metadata staging without a build remain available without runtime evidence.
Prepare-only runs that attach a build are gated.

Validate the report without an App Store Connect request before dispatching the
live workflow:

```sh
scripts/submit-app-store-review.py \
  --platform <MAC_OS|IOS|VISION_OS|TV_OS> \
  --version <marketing-version> \
  --build-number <coordinated-build-number> \
  --validation-report .build/validation-report.json \
  --validation-train release \
  --release-evidence-report .build/release-evidence.json \
  --release-evidence-mode enforce \
  --release-evidence-comparison .build/release-comparison.json \
  --release-evidence-expected-build-manifest \
    .build/ExpectedBuildManifest-platform.json \
  --release-evidence-selected-rc-ledger \
    .build/release-evidence-rc-lineage.json \
  --validate-report-only
```

Repeat `--release-evidence-expected-build-manifest` for the complete shipping
surface set. Also supply `--release-evidence-previous-ledger` or
`--release-evidence-host-os-evidence` when those inputs were used to generate
the ledger. The preflight reconstructs the enforced ledger and fails closed if
any authoritative generation input is omitted or changed.

Each platform's runtime surfaces are:

- `MAC_OS`: Mac app, widget, and refresh agent.
- `IOS`: iPhone app/widget, iPad app/widget, Watch app, and complication.
- `VISION_OS`: Vision Pro app and widget.
- `TV_OS`: Apple TV app and Top Shelf extension.

The check requires exact-build proof for the platform's surfaces listed in the
comparison's `requiredSurfaces.actual-runtime`, which are the ones whose runtime
changed. A platform with no runtime change needs no runtime session. Without a
comparison, every runtime surface of the platform is required. Every requested
session surface must appear exactly once and be proven. All platform
submissions also require the canonical Mac Production runtime because it is
the companion data publisher. `IOS` review evidence requires the documented
physical Watch restart attestation when a Watch surface needs proof. This release gate is stricter than the routine companion product
check below, where one iPhone or iPad may be sufficient for a targeted smoke
test.

This remains a narrow exact-build runtime stop within the complete release
policy. The coordinator reports runtime and fresh visual approval state; that
report alone does not evaluate approval carry-forward, host-OS compatibility,
or exact-RC reuse. The full release evaluator in
[`context_panel_release_gate/core.py`](../scripts/context_panel_release_gate/core.py)
implements those checks through `_carried_evidence`, `_host_os_compatible`,
`evaluate_release_evidence`, and `release_evidence_report_blockers`.
[`submit-app-store-review.py`](../scripts/submit-app-store-review.py) supplies the
current policies, complete build manifests, lineage, and host-OS evidence to
reconstruct the release verdict. Implemented checks still require
valid candidate evidence; neither coordinator success nor implemented integration
establishes that a particular train is approved.

When the exact Watch build is confirmed, the coordinator requests the existing
post-install restart without performing it. After the physical restart, record
the operator attestation so later status reads do not repeat the request:

```sh
scripts/context-panel-validation.py record-watch-restart \
  --version <marketing-version> \
  --build-number <coordinated-build-number>
```

The record command first confirms that the exact Watch build is still observable
and otherwise exits `30` without writing the attestation. When a durable session
is active, the attestation is stored in that session. Older flat local
attestations migrate on first session creation. That local record does not prove
complication runtime; the routine Watch test below remains authoritative.

The sandbox-local widget mirror is a local-development fallback, not a
substitute for release app-group entitlements. The `install` and `reset` runtime
baseline modes unregister stale PluginKit and Launch Services paths and
quarantine competing local bundles; the read-only `check` mode fails while such
registrations or bundles remain.

1. Install and launch the canonical Mac app from `/Applications/Context
Panel.app`.
2. Before opening a signed validation coordinator session or touching a physical
   companion device, run the read-only generated-bundle preflight on the trusted
   release host:

   ```sh
   scripts/context-panel-companion-cache.sh preflight
   ```

   Require `companion-cache preflight=OK`. A failure reports bounded bundle
   classifications and counts without printing device, account, or provider
   data. The scan includes checkout-scoped cache roots plus current and legacy
   temporary retry layouts left by interrupted validators. Investigate the exact
   validated root before mutation. When the residue is confirmed to be unsigned
   output from the generic companion validator, quarantine only that root:

   ```sh
   scripts/context-panel-companion-cache.sh quarantine \
     --root <absolute-.build-or-derived-data/companion-build-validation-root>
   ```

   The quarantine command rejects unrelated, root-level, traversing, symlinked,
   and signed-content roots. It does not delete DerivedData, compiler caches,
   manifests, runtime receipts, release evidence, or unrelated bundles.

3. Run the read-only Production receipt:

   ```sh
   scripts/context-panel-runtime-baseline.sh check --require-production-runtime
   ```

   If the validator checkout has advanced past the approved candidate, use its
   sealed `ExpectedBuildManifest-macos.json` with `--candidate-manifest` as
   described in [the candidate validation route](validation-authority.md#validation).
   Keep running the current validator; do not switch to the candidate's older
   validation code or substitute another build.

   Require `baseline=OK`, `app-cloudkit=Production`, and
   `refresh-agent-cloudkit=Production`. Do not run `install` or `reset`; those
   modes build a local Development-CloudKit runtime and refuse to replace the
   signed Production publisher.

4. Trigger a Mac refresh that publishes the sanitized companion snapshot to
   CloudKit.
5. Open the app Diagnostics view and confirm `Companion publish` is healthy or,
   if degraded, names the failing store without raw paths or account data.
6. Install the companion build from TestFlight on the target device. For the
   current validated companion lane, that means iPhone or iPad. For visionOS,
   release evidence requires Apple Vision Pro; #168 records the completed
   initial packaging requirements. A visionOS simulator can be used for a
   separate pre-release UI smoke check, but not as TestFlight/device validation.
7. Before launching the companion app, add the companion widget and confirm its
   small/medium/large layouts render current lanes directly from Production
   CloudKit rather than setup-only, stale, or no-Mac state.
8. Launch the companion app and confirm it renders the same current lanes,
   mirrors the selected snapshot into the App Group, and preserves useful
   degraded states in both app and widget.
   For watchOS, add the complication before launching the Watch app and confirm
   it reads the Production CloudKit snapshot directly. Then launch the Watch app
   and confirm its explicit timeline reload preserves the same answer. For an
   upgrade, follow the routine Watch restart runbook below before judging the
   complication.
9. Reopen the Mac Diagnostics view and confirm companion load/readback state is
   explainable: healthy, stale, unavailable, partial, or failed.
10. Exercise degraded cases when practical: CloudKit disabled or unavailable,
    missing CloudKit record, stale local mirror, missing Mac publish, delayed
    notification, and app group mirror failure.
11. For multi-Mac validation, use two Macs signed into the same iCloud account
    with at least one OpenAI account available on only one Mac. Publish from the
    fully authenticated Mac, then refresh and publish from the partial Mac.
    Confirm iOS and watchOS retain healthy OpenAI lanes, include healthy lanes
    unique to either Mac, preserve their original observation times, and do not
    accumulate duplicate companion account IDs. Reverse the publish order and
    repeat so CloudKit conflict retry and account-level freshness both have
    coverage.
12. During the rolling-upgrade test, leave one Mac on the previous release and
    update the other Mac plus iOS/watchOS companions. Confirm the new companion
    clients merge the legacy `current` record with the versioned usage record,
    and confirm repeated legacy publishes cannot erase lanes already preserved
    in the versioned record.

#### Security-Scoped Bookmark QA

Before treating a fresh macOS train as release-ready:

1. Authorize one configured Codex auth file and its telemetry directory from
   the signed app, then confirm a refresh produces provider limits and
   prompt-cache telemetry.
2. Run the Production runtime receipt once to inspect the refresh agent's
   aggregate bookmark summary, then rerun it with
   `--expect-bookmark-current <count>` and
   `--expect-bookmark-resolvable <count>` set to the explained release
   expectations. Strict mode requires every stored entry to use the current
   format, rejects legacy, document-scoped, and invalid entries, and requires the
   expected number of resolvable entries. A check without those expectation
   flags proves only that the privacy-safe summary can be read; it is not an
   access-health verdict. The receipt must never print bookmark payloads, raw
   paths, or account identifiers.
3. Replace the authorized auth file atomically, refresh again, and confirm the
   bookmark remains readable and is renewed rather than remaining stale.
4. Reauthorize the same configured path and confirm it replaces the prior entry
   without removing sibling authorizations.
5. Make one configured usage source temporarily unreadable while another stays
   healthy. Confirm the healthy source advances and the unreadable source keeps
   its last-good mirror instead of being purged.
6. Quit the main app, run or await the signed login-item refresh agent, and
   confirm refresh diagnostics plus snapshot time advance. Record whether the
   aggregate bookmark summary shows app-created bookmarks as resolvable from the
   separately sandboxed agent. If it does not, confirm provider refresh uses the
   shared Keychain credential and prompt-cache telemetry preserves the last-good
   main-app mirror; do not claim direct agent bookmark access.
7. Upgrade over the previous signed build and repeat the receipt. Treat a change
   between Developer ID and Mac App Store sandbox identities as a separate
   reauthorization scenario rather than ordinary in-place upgrade evidence.

#### Routine Watch Complication Test

1. Confirm the new marketing version and build number reached the Watch, not
   only the paired iPhone, while preserving existing complication placements.
2. Restart the Watch after the installation completes.
3. After the restart, test the real production complication, Watch app reload,
   shared-cache agreement, and degraded-state behavior.
4. Follow the [Watch restart rule](validation-authority.md#validation) for
   pre-restart output, in-place upgrade investigations and recovery.

If the companion app or widget is stale but diagnostics show healthy Mac publish
and readable CloudKit state, follow the companion receive/mirror/reload
diagnostics established by #456 before treating provider refresh as the cause.

## App Store Review Submission

After the uploaded build is processed, run the `Submit App Store Review` workflow
with the App Store marketing version, uploaded build number, and App Store
release notes. For a live build attachment or submission, also publish the
[submission evidence bundle](#submission-evidence-bundle) and pass its SHA-256
as `evidence_bundle_sha256`. The workflow calls
`scripts/submit-app-store-review.py`, which
creates or reuses the App Store version for the selected platform, attaches the
validated platform-matching build, copies localization and review-contact
metadata from an existing version, updates `What's New`, and submits the review
submission. Use `dry_run: true` to validate the metadata source, uploaded build,
blocked-version recovery path, and target version path without creating,
updating, or submitting App Store review objects.

A live submission and the `--validate-report-only` preflight also need a
passing `shared-view-simulator-references` CI job on each source commit the
expected-build manifests name, from a push or manual run of CI. CI
skips that job when a change cannot affect it, so the release commit may not
have one. The helper then refuses and prints how to get one: push a branch at
that commit and dispatch CI on it. It reads the runs from the GitHub API, with
`GH_TOKEN` when set.

### Submission evidence bundle

GitHub caps all `workflow_dispatch` inputs at 65,535 characters in total, and a
full release's evidence is several times that. The workflow therefore reads the
evidence from Git, pinned by a digest the dispatcher supplies:

1. Pack the exact files that passed `--validate-report-only`. Pass the same
   optional inputs the release gate used (`--previous-ledger`,
   `--host-os-evidence`, `--historical-policy-archive`):

   ```sh
   scripts/submission-evidence-bundle.py create \
     --version <version> --build-number <build-number> \
     --validation-report .build/validation-report.json \
     --release-evidence-report .build/release-evidence.json \
     --comparison .build/release-comparison.json \
     --expected-build-manifest .build/ExpectedBuildManifest-macos.json \
     --expected-build-manifest .build/ExpectedBuildManifest-ios.json \
     --expected-build-manifest .build/ExpectedBuildManifest-visionos.json \
     --expected-build-manifest .build/ExpectedBuildManifest-tvos.json \
     --selected-rc-ledger .build/release-evidence-rc-lineage.json \
     --output .build/submission-evidence.json
   ```

   It prints the branch name and `evidence_bundle_sha256`.
2. Commit the bundle as `submission-evidence.json` at the root of an orphan
   branch named `release-evidence/<version>-<build-number>` and push it with
   the bot helpers. No workflow runs on that branch. The evidence is public by
   design; the reports exclude device, account, credential and App Store
   Connect identifiers.
3. Dispatch `Submit App Store Review` from `main` with the same version and
   build number and `evidence_bundle_sha256`. Use the same bundle for every
   platform.

The workflow keeps its protected-main guard and release-intent record. It
fetches the branch, refuses the bundle unless its SHA-256, version and build
number match the dispatch, and unpacks each file byte for byte. It then runs the
same validation as the local route, against the policy files at the protected
`main` commit. A missing branch, a changed bundle or a missing digest on a live
run fails before any App Store Connect request. The branch can be deleted
after the version is live.

If the workflow cannot be used, the local operator route at the end of this
section remains the fallback. It skips the protected-main guard and the
release-intent record, so record why on the release issue.

Preferred operator flow:

1. Validate and dogfood the build through TestFlight first.
2. Run `Submit App Store Review` with `dry_run: true` using the exact marketing
   version, platform, build number, and release notes intended for review.
   The selected build's pre-release marketing version must match the App Store
   marketing version; do not attach an older companion build to a fresh App
   Store version.
   For the first version on a new platform, set `copy_from_platform` to an
   existing platform such as `MAC_OS` and `copy_from_version` to the approved
   source version. Review the copied text for platform-specific claims before
   submission.
3. If the dry run reports that an older App Store version blocks creating the
   target version, rerun the dry run with `remove_active_review_version` set to
   that blocking version.
   Pass `evidence_bundle_sha256` in the dry run too, so the evidence is
   validated before the live run.
4. After the dry run succeeds, rerun the same inputs with `dry_run: false` to
   submit review.

App Store Connect accepts exactly one App Store version item per review
submission. Run `Submit App Store Review` separately for each platform and
marketing version; do not group internal version IDs into one submission. The
helper creates a platform-tagged, app-only review submission and immediately
attaches exactly one version item. That item is the ownership record: a retry
may reuse a submission only when App Store Connect exposes the exact target
version through the item or a legacy direct-version relationship. Itemless
submissions are never reused because they do not identify a marketing version;
if they exhaust App Store Connect's active-submission limit, the helper fails
closed and prints the active submissions for operator inspection. A partial
same-version retry remains idempotent after item creation, including when two
jobs race and the winning item becomes visible on a different submission. The
losing job revalidates its own submission immediately before cleanup and attempts
to cancel it only while the authoritative items endpoint still reports it empty.
Cleanup verification or cancellation failure is reported without blocking the
valid owner's submission. If item creation fails, a submission created by that
run is cleaned up only after an authoritative read still proves it empty;
unknown ownership or a newly visible item leaves it untouched and preserves the
original error. A process interruption before item creation can still
leave an ownerless draft. The helper never guesses its version and instead fails
closed with active-submission diagnostics if those drafts exhaust the service
limit.

Rejected App Store versions are not release candidates. They may be useful as
audit targets while cleaning screenshots or copying metadata, but do not submit
or dry-run-submit the same rejected marketing version again. Prepare the next
marketing version, copy the approved metadata and screenshot matrix there, and
submit that fresh version instead. The submit helper fails fast when the target
version is in `DEVELOPER_REJECTED`, `REJECTED`, `METADATA_REJECTED`, or
`INVALID_BINARY`, except the explicit developer-withdrawn replacement described
below.

Companion App Review may ask for a demo video when the iOS, iPadOS, watchOS,
visionOS, or tvOS surface depends on a Mac-published CloudKit companion
snapshot. For Guideline 2.1 information-needed responses, add an App Review
Information link to a demo video filmed on physical hardware. Show the current
companion app on a physical iPhone or iPad, the Mac running Context Panel as the
designated hardware/source app, the Mac publishing a fresh snapshot, and the
companion app or widget moving from setup/waiting-for-Mac-sync into synced
usage-limit data. For `TV_OS`, record the equivalent flow on a physical Apple
TV, including app launch, the waiting/no-Mac state, and the transition to a fresh
Mac-published snapshot.
Reply to App Review with that link and summarize that no demo account is needed
unless the build requires one.

`tvos_demo_video_url` is optional for ordinary `TV_OS` updates. Provide a
reviewer-accessible HTTPS physical Apple TV recording when App Review asks for
current hardware evidence, or when a new tvOS surface otherwise needs a physical
demo path. When supplied, the submit helper replaces copied prior-version notes
with a standardized physical Apple TV evidence block plus any explanatory
`review_notes`; an invalid URL fails before any App Store Connect mutation. When
neither a current video nor current review notes are supplied, the helper
clears copied prior-version review notes during both prepare-only and submission
runs so an exact-build recording from an older version cannot silently carry
forward.
Dry runs report that pending clear without changing App Store Connect.

Use `platform: MAC_OS` for the native macOS app. For companion review, first run
the companion App Store Connect upload for `platform=ios`, `platform=visionos`,
or `platform=tvos`, then run `Submit App Store Review` separately with
`platform: IOS`, `platform: VISION_OS`, or `platform: TV_OS` and the companion
build number. If App Store Connect says the app needs an approved iOS version or
an iOS version under review, do not retry the macOS submit as the fix; upload and
submit the companion iOS review path as its own review submission.

Cancel-only recovery is available through `Submit App Store Review` by setting
`cancel_review_only: true` and `remove_active_review_version` to the version
whose active review should be withdrawn. That path exits after cancellation and
cannot submit a replacement build as a side effect, so it does not require a
build number or release notes. Use `dry_run: true` first to verify the target
review/version.

If Apple refuses submitted-item removal because of the owning submission's
state, the helper reads every page of that submission's items. It cancels the
submission only when its sole item is the exact item and version being
withdrawn. Any additional item, unknown ownership, or different version keeps
the refusal. It reads cancellation back to `COMPLETE` or confirms Apple returns
404 for the canceled submission, and in either case verifies the exact withdrawn
version is `DEVELOPER_REJECTED` before continuing; an
unconfirmed cancellation stops the run for reconciliation. The dry run reads
the same item inventory and reports whether this fallback is available, without
changing App Store Connect. This scope check applies to all four platforms.

App Store Connect can retain an itemless `READY_FOR_REVIEW` draft that points to
an already released version and has no platform or submission date. The helper
does not treat that proven orphan shape as an active cross-platform review
blocker. Cancel-only recovery can cancel the draft review submission directly;
other direct-version review submissions remain blocking unless their normal
review item or submission state is explicitly removed.

When submitting a replacement version, `remove_active_review_version` is not
cancel-only. It allows the submit script to remove or reuse an existing blocked
App Store version, then continue creating the target version and submitting the
new build after the dry-run path has validated that transition.

After a completed withdrawal, dry-run and live replacement allow the explicitly
named `DEVELOPER_REJECTED` source to become a different marketing version with
a matching validated new build, only when no active review remains on that
platform. If Apple blocks creating a separate version, this permits updating
the withdrawn version's number and build before submitting the replacement.
A resumed target may continue this same replacement only when the old version
name is absent and authoritative review items prove either no active owner or
one owner exclusively for that exact target. Unknown, mixed, duplicate or
ownerless active submissions refuse before target updates. Known other-platform
reviews and proven empty released-version orphans are preserved. Apple-rejected
sources and targets retain their refusal. A withdrawn target requires an explicit
absent old source, a distinct target, and a validated build. App Store Connect
does not expose rename history; the old-source input declares replacement intent.

For the local operator route, the same script accepts an API key path or the
existing App Store Connect environment variables. Run it from a clean checkout
of protected `main`. A live run takes the schema gate first and the same
evidence flags as the preflight above, without `--validate-report-only`:

```sh
scripts/cloudkit-schema-gate.py check &&
  scripts/submit-app-store-review.py \
  --platform MAC_OS \
  --version <version> \
  --build-number <build-number> \
  --whats-new "<approved release notes>" \
  <evidence flags from the preflight>
```

### Direct App Store Connect API Checks

When asked to check App Store Connect state through the API, prefer the direct
local API path before falling back to a GitHub workflow dispatch. The workflow is
API-backed, but it is not the same operational evidence as a direct local API
query.

Use the private local App Store Connect operator config when present. Keep host,
account, key ID, issuer ID, private key path, JWTs, and App Store Connect object
IDs out of public repo docs, issues, PR descriptions, and agent summaries unless
Chris explicitly asks for a private handoff. Document only the generic mechanism:

- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_API_KEY_P8_BASE64`, or `--api-key <private-key-path>`

For Chris's local operator machine, first check for a private shell env file at
`~/.appstoreconnect/asc.env`; source it only into the current command process
and do not print its values. If it provides the key ID and issuer ID but not the
key material, look for the matching private key under
`~/.appstoreconnect/private_keys/` and pass it with `--api-key`. Keep exact key
filenames and all values out of public docs, issues, PRs, and summaries.

For a read-only active-review check, run the submit helper in `--dry-run` mode.
For example, this validates that a selected version is attached to an active
review submission without changing App Store Connect:

```sh
scripts/submit-app-store-review.py \
  --platform IOS \
  --version <marketing-version> \
  --remove-active-review-version <marketing-version> \
  --cancel-review-only \
  --dry-run \
  --api-key <private-key-path>
```

If the direct local config is unavailable, say that explicitly and then use the
GitHub `Submit App Store Review` workflow with `dry_run: true` as a fallback.
When reporting results, distinguish direct local ASC API evidence from
workflow-mediated ASC API evidence.

The App Store Connect upload scripts fail early when any supplied provisioning
profile does not authorize the Context Panel App Group; App Store profiles may
express that authorization as either the exact app group or a same-team
wildcard. Per-bundle profile requirements are in
[Required Signing Material](#required-signing-material).

## Build The Native App And Widget

```sh
xcodegen generate --spec project.yml
xcodebuild \
  -project ContextPanel.xcodeproj \
  -scheme ContextPanel \
  -configuration Debug \
  -destination 'platform=macOS' \
  -allowProvisioningUpdates \
  build
```

This builds `Context Panel.app`, embeds `ContextPanelWidgetExtension.appex`
under `Contents/PlugIns`, and embeds `ContextPanelRefreshAgent.app` under
`Contents/Library/LoginItems`. The app, refresh agent, and widget carry the
`MM5YXC7T6E.group.com.shinycomputers.contextpanel` App Group entitlement and
share snapshots through the App Group container when it is available. Release
and App Store Connect upload signing need explicit provisioning profiles for all
three bundle identifiers:
`com.shinycomputers.contextpanel`, `com.shinycomputers.contextpanel.widget`, and
`com.shinycomputers.contextpanel.refresh-agent`.

The Xcode project is generated from `project.yml`; update the spec and
regenerate rather than editing the project by hand.

## Build A Native App Artifact Locally

```sh
scripts/package-native-macos-app.sh --version 1.0.0 --output dist --identity -
```

The native packaging script regenerates `ContextPanel.xcodeproj`, builds the
`ContextPanel` Xcode scheme in Release configuration, copies
`Context Panel.app` to `dist`, signs the embedded widget extension and the app,
verifies the resulting bundle, optionally notarizes, and writes a zip artifact.

Use `--identity -` for ad-hoc local validation. With `--identity auto`, the
script prefers one unambiguous Developer ID Application certificate, then one
Apple Distribution or Apple Development certificate, and otherwise uses ad-hoc
signing. Ambiguous identity classes fail instead of choosing the first common
name. Every selected identity is resolved to its exact SHA-1 fingerprint before
signing. Signed Release packaging requires explicit provisioning profiles for
the app, widget, and refresh agent from the same certificate set.

Use `--notarize` only with a Developer ID identity and either Apple notarization
environment variables, App Store Connect API credentials, or a stored notarytool
profile:

```sh
scripts/package-native-macos-app.sh \
  --version 1.0.0 \
  --output dist \
  --identity auto \
  --app-provisioning-profile path/to/ContextPanel.provisionprofile \
  --widget-provisioning-profile \
    path/to/ContextPanelWidgetExtension.provisionprofile \
  --refresh-agent-provisioning-profile \
    path/to/ContextPanelRefreshAgent.provisionprofile \
  --notarize \
  --notary-key ~/.appstoreconnect/private_keys/AuthKey_EXAMPLE.p8 \
  --notary-key-id EXAMPLE \
  --notary-issuer 00000000-0000-0000-0000-000000000000
```

## Build The SwiftPM App Shell

```sh
scripts/package-macos-app.sh --output dist --identity auto
```

The script builds `ContextPanelApp` in release mode, wraps it as
`dist/Context Panel.app`, writes app metadata, signs the bundle, verifies the
signature, and runs a local Gatekeeper assessment.

`--identity auto` asks Keychain for available code-signing identities and
prefers `Developer ID Application`, then `Apple Development`, then ad-hoc
signing. The script does not read private keys or credentials; signing is
performed by macOS Keychain through `codesign`.

Useful variants:

```sh
scripts/package-macos-app.sh --debug
scripts/package-macos-app.sh --identity -
```

## Current Constraints

- CI can upload an ad-hoc validation artifact to its workflow run. The
  [GitHub publication gate](#ci-signing-and-notarization-secrets) refuses it as
  a GitHub Release.
- Friend-installable CI releases require Developer ID signing secrets and
  notarization secrets.
- The older `scripts/package-macos-app.sh` bundle contains the SwiftPM preview
  app only and does not embed the WidgetKit extension.
- Release builds must keep the
  `MM5YXC7T6E.group.com.shinycomputers.contextpanel` App
  Group entitlement on the app, WidgetKit extension, and refresh agent. The app
  and refresh agent must also keep sandbox, outbound network, and app-scope file
  bookmark entitlements. The native packaging script verifies those entitlements
  after signing and fails before producing an artifact if any required bundle is
  missing them.
- A launched canonical runtime receipt requires an active WidgetKit timeline
  whose modification time is at least as new as the installed build fingerprint.
  Older render caches are diagnostic evidence only and cannot prove that the
  newly installed widget extension launched successfully.
