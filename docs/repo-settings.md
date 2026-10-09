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
  Superseded PR analyses cancel without waiting for trusted temp cleanup to
  acquire a runner. Cleanup runs after success or failure unless the workflow
  was cancelled. The next trusted analysis sweeps direct child directories older
  than two hours under `/tmp/context-panel-codeql`; fork analyses do not use or
  clean that root. Required analysis evidence and the #699 sandbox workaround
  are unchanged.
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
- Release environments, activation and owner setup: follow the single authority
  in [the release guide](release.md#one-time-no-click-setup-owner-only).
- Release environment secret: `CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_KEY`, at
  least 32 bytes of high-entropy key material shared with the operator Keychain
  entry that seals Production CloudKit schema receipts. Its sole GitHub copy
  belongs in `release`; never store its value in repository files.
- Immutable Releases: enabled so newly published GitHub Releases lock their tag,
  title, notes, and assets after publication.

Implementation work should happen on focused branches with pull requests.
