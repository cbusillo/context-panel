# macOS And Companion Release Path

[Validation](validation-authority.md) says what proves a release.

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

App Store Review submission is separate from `Ship`. Submit the TestFlight
build after about a day on TestFlight; see
[App Store Review Submission](#app-store-review-submission).

## Definition of released

Every platform ships together as one release, with one version and build:
Mac, iPhone and iPad with the embedded Watch app, Vision Pro, and Apple TV
([Q451](https://github.com/cbusillo/context-panel/issues/835#issuecomment-6235390539)).

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
The submission gate reads this record's source commit and upload time;
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
hide drift, until the check has seen their version live; after that a later
unreadable page posts nothing. Records closed as not planned are excluded from
alert targets.
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
approve, release, or change App Store Connect.

## Release cadence

TestFlight and App Store releases run on different clocks.

- **TestFlight (internal):** ship whenever a change is worth trying on a
  device. Chris installs on the Mac from TestFlight when a check needs the
  installed app.
- **App Store:** submit a TestFlight build after about a day on TestFlight.
  Agents suggest an App Store release when user-facing changes have built up,
  or when a fix matters to users. Chris decides.
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
solely to test this change. Signing, notarization and exact-source CloudKit schema
receipts remain required on their existing paths.

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
`ContextPanelWidgetExtension.appex`. Merging a PR or creating a tag does not trigger the
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
hashes, and per-surface fingerprints. The input mapping and CLI are documented in
[Build Fingerprints](build-fingerprints.md).

The apps no longer write the two CloudKit runtime record types from the
retired release proof round. Production cannot drop deployed record types, so
the checked-in CloudKit schema still lists them; leave them there.

The fingerprint contract hashes normalized target slices from `project.yml`,
not generated `ContextPanel.xcodeproj` output. XcodeGen formatting or object-ID
changes therefore cannot change unrelated fingerprints. Unknown or unmapped
inputs produce an `unknown` embedded manifest during ordinary builds and fail
the commit gate.

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
[schema publication gate](#cloudkit-production-schema-gate); these inputs do
not bypass it.
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
remains only the unsigned compiler gate. A release also needs a signed upload
from `main`, the live Production CloudKit schema gate, and TestFlight
distribution.

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

Before companion TestFlight distribution or App Store Review, validate that
Production contains the contracts in `CloudKit/companion-sync.schema.ckdb`.

Run the offline repo contract check before packaging:

```sh
scripts/validate-cloudkit-companion-schema.sh
```

The checked-in `CloudKit/companion-sync.schema.ckdb` file is the exact additive
schema candidate. It preserves the existing companion and `Users` definitions,
keeps the two retired runtime record types that Production already has,
includes their range index, and omits public-database grants for them. Do not reconstruct the candidate by
hand in CloudKit Console.

Every build also checks the app against that contract without credentials:
Swift tests build the companion snapshot records the app writes and compare each record's type, name, fields and value types with
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
it. For a live release command
run locally, run `scripts/cloudkit-schema-gate.py check` first; it uses the
token `cktool` saved in the Keychain.

The live gate uses Apple's `cktool`, not the App Store Connect API key. `cktool`
needs a CloudKit management token. Apple documents that management tokens are
generated from CloudKit Console settings, are scoped to the developer team and
user, default to a one-year lifetime, and can be revoked from CloudKit Dashboard
settings. `cktool` can then save the token securely in the Mac Keychain.

The schema gate does not promote a new `CKSubscription` definition. The retired
runtime session and receipt record types have no subscription. Context
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

Re-export Development and run the live Development gate before using
CloudKit Console's **Deploy Schema Changes** action. Do not import directly into
Production and never use `cktool reset-schema`; reset deletes Development data.
After deployment, re-export Production and require the live Production gate to
pass before re-running Mac publish and companion TestFlight validation.

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
badge. Every submission needs screenshot, metadata, privacy, and reviewer
evidence, including any demo video App Review asks for.

## App Store Review Submission

An App Store release is the TestFlight build. Nothing is collected for it at
release time; [validation](validation-authority.md#what-proves-a-release) says
what proves it.

1. Ship the release (see [Normal Ship Workflow](#normal-ship-workflow)). Every
   platform's build goes to TestFlight, and Ship opens one release record per
   platform.
2. Leave the build on TestFlight for about a day. Use it if you like; nothing
   requires it.
3. Submit all four platforms with one command:

   ```sh
   for platform in MAC_OS IOS VISION_OS TV_OS; do
     gh workflow run submit-app-store-review.yml --repo cbusillo/context-panel --ref main \
       -f platform="$platform" -f version=<version> -f build_number=<build-number> \
       -f whats_new="<release notes>" -f dry_run=false
   done
   ```

   Run it with `dry_run=true` first if you want to see the version path and
   whether the gate passes yet. A dry run reports the gate but never stops on
   it.

`Submit App Store Review` submits a platform's build only when:

- the release commit, from Ship's release record for that platform, version
  and build, has a passing `shared-view-simulator-references` CI job from a
  push or manual run of CI; and
- the build has been on TestFlight for 24 hours, counted from when Ship (or a
  Ship retry) reported its TestFlight distribution as successful on that
  record, and the TestFlight crash watcher filed no crash report for that exact
  platform and build in those 24 hours. A build distributed to TestFlight
  outside Ship never starts the day; use the override.

Chris can skip the wait, or submit despite a crash report, with
`-f skip_soak_reason="<why>"`. The run log and summary record the reason. The
reference job is never skipped. CI skips that job when a change cannot affect
it, so the release commit may not have one; the helper then refuses and prints
how to get one: push a branch at that commit and dispatch CI on it. A build
without a Ship release record is refused, because the gate needs its commit
and upload time. The checks live in
[`scripts/app_store_submission_gate.py`](../scripts/app_store_submission_gate.py)
and read GitHub with the workflow token.

The workflow calls `scripts/submit-app-store-review.py`, which creates or
reuses the App Store version for the selected platform, attaches the validated
platform-matching build, copies localization and review-contact metadata from
an existing version, updates `What's New`, and submits the review submission.
The selected build's pre-release marketing version must match the App Store
marketing version. For the first version on a new platform, set
`copy_from_platform` to an existing platform such as `MAC_OS` and
`copy_from_version` to the approved source version, and review the copied text
for platform-specific claims. If a dry run reports that an older App Store
version blocks creating the target version, rerun it with
`remove_active_review_version` set to that blocking version.

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
of protected `main` with `GH_TOKEN` set so the gate can read GitHub. A live run
takes the schema gate first. It skips the protected-main guard and the
release-intent record, so record why on the release issue:

```sh
scripts/cloudkit-schema-gate.py check &&
  scripts/submit-app-store-review.py \
  --platform MAC_OS \
  --version <version> \
  --build-number <build-number> \
  --whats-new "<approved release notes>"
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
