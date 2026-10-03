# Repository Settings

Expected GitHub settings:

- Visibility: public.
- Default branch: `main`.
- Issues: enabled.
- Projects: enabled.
- Discussions: enabled.
- Wiki: disabled.
- Delete branches on merge: enabled.
- Merge commits: enabled.
- Squash and rebase merges: disabled.
- Dependabot: enabled for Swift Package Manager and GitHub Actions.
- CodeQL: enabled for Swift on pull requests, pushes to `main`, weekly schedule,
  and manual dispatch.
- Default branch rulesets, all active:
  - `Protect main`: the rules below, with merge commits as the only merge
    method.
  - `Code-owner review for DIRECTION.md`: requires code-owner review for files
    a `CODEOWNERS` file assigns. This repository has no `CODEOWNERS` or
    `DIRECTION.md` file today, so it adds no reviewer.
  - `Only the owner and automation update the default branch`.
- Required pull requests: enabled for `main`.
- Required status checks on `main`: `swift` and `Analyze Swift`, with strict
  status checks enabled.
- Code scanning gate on `main`: CodeQL must not report quality alerts at
  `errors` or security alerts at `high_or_higher`.
- Code quality gate on `main`: enabled for `errors`.
- Force pushes and branch deletion: blocked for `main`.
- Review environment: `release-approval`, with `cbusillo` as required reviewer,
  self-review allowed, administrator bypass disabled, no wait timer and no
  secrets. Selected deployment **Branch** rule: `main` only.
- Secret environment: existing `release`, with no reviewer or wait timer and a
  selected deployment **Branch** rule for protected `main` only. Every GitHub
  release secret lives only here. Ship preflight and all six standalone/channel
  workflows use it after a secretless review gate. No duplicated secret store.
- Activation variable: repository Actions variable `RELEASE_APPROVALS_CONFIGURED`
  is exactly `true` only after the owner confirms the role move and secret-name
  inventory. Unset/false pauses new release workflows before environment jobs.
  Removing it does not restore reviewer settings or stop an already running job;
  it blocks any channel guard that has not yet passed, even in an approved run.
  Never delete or unprotect `release-approval` while activation is true. Unset
  activation first and finish/cancel pending release runs before changing it.
  The owner may explicitly enable an interim route with both environments
  reviewed while historical runs age out; that route still has extra prompts.
  Previous `RELEASE_CHANNELS_CONFIGURED` is obsolete and should be removed.
- `release-channels` is unused; confirmed duplicate secrets there and at
  repository level are removed by the owner after older runs finish. Leave
  existing `release` values untouched; stop on a missing sole-store name.
- Release environment secret: `CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_KEY`, at
  least 32 bytes of high-entropy key material shared with the operator Keychain
  entry that seals Production CloudKit schema receipts. Its sole GitHub copy
  belongs in `release`; never store its value in repository files.
- Immutable Releases: enabled so newly published GitHub Releases lock their tag,
  title, notes, and assets after publication.

Implementation work should happen on focused branches with pull requests.
