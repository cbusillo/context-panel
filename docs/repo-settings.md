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

Implementation work should happen on focused branches with pull requests.
