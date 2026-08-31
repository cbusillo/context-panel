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
- Default branch ruleset: active ruleset named `Protect main` targeting the
  default branch.
- Required pull requests: enabled for `main`.
- Required status checks on `main`: `swift` and `Analyze Swift`, with strict
  status checks enabled.
- Code scanning gate on `main`: CodeQL must not report quality alerts at
  `errors` or security alerts at `high_or_higher`.
- Code quality gate on `main`: enabled for `errors`.
- Force pushes and branch deletion: blocked for `main`.
- Release environment: active environment named `release` with a required
  repository-owner review, administrator bypass disabled, and deployment
  branches restricted to protected branches only. Because `main` is the only
  protected branch, secret-bearing release jobs cannot run from tags or task
  branches.
- Release environment secret:
  `CONTEXT_PANEL_CLOUDKIT_SCHEMA_RECEIPT_KEY`, containing at least 32 bytes of
  high-entropy key material shared with the operator Keychain entry used to seal
  Production CloudKit schema receipts. Do not store the value in repository
  files or repository-level secrets.
- Immutable Releases: enabled so newly published GitHub Releases lock their tag,
  title, notes, and assets after publication.

Implementation work should happen on focused branches with pull requests.
