# Developer Artifacts Handoff

Use `/Volumes/Developer-Artifacts` for high-churn local developer and
self-hosted runner artifacts. Keep the layout purpose-based from the start so
Context Panel can share the volume with other projects without guessing what is
safe to delete or move.

## Recommended Layout

- `/Volumes/Developer-Artifacts/github-actions/runners/` for self-hosted runner
  installations.
- `/Volumes/Developer-Artifacts/github-actions/cache/` for reusable build caches
  that should survive checkout cleanup.
- `/Volumes/Developer-Artifacts/github-actions/tmp/` for disposable workflow
  scratch data.

Repository-specific cache leaves should include owner, repo, and workflow or
purpose names:

```text
/Volumes/Developer-Artifacts/github-actions/cache/cbusillo/context-panel/<purpose>/
```

For Swift/Xcode work, prefer cache leaves such as:

```text
/Volumes/Developer-Artifacts/github-actions/cache/cbusillo/context-panel/swiftpm/
/Volumes/Developer-Artifacts/github-actions/cache/cbusillo/context-panel/derived-data/
```

Do not put long-lived caches under a GitHub Actions checkout. Checkout cleanup
can remove them before the next job can reuse them.

## Runner Migration Pattern

Move active runner installations only between jobs:

1. Let any in-flight job finish or fail naturally.
2. Stop the launchd service for the runner.
3. Copy the runner directory to
   `/Volumes/Developer-Artifacts/github-actions/runners/<runner-name>/`.
4. Reinstall or update the service from the new path.
5. Verify the runner is online in GitHub and runs a small job.
6. Remove the old home-directory runner copy only after verification.

Do not move an active runner directory while a job is running from it.

## Codex Lab Reference

Codex Lab started with the macOS app build cache because it was the slowest
self-hosted runner check. Its app workflow uses a persistent Cargo target cache
under:

```text
/Volumes/Developer-Artifacts/github-actions/cache/<owner>/<repo>/codex-lab-app/
```

The first run still behaves like a cold build because it fills the cache. Later
runs should be faster because checkout cleanup no longer deletes the target
tree.

## Non-Mac Compile Host

Use `chris-testing` over SSH for non-macOS compile work when practical. It is a
Linux x86_64 host and should be faster for non-Mac builds than local macOS
runners.

Current read-only probe:

```text
host=chris-testing
os=Linux x86_64
cpus=50
git=/usr/bin/git
cargo=not found in default PATH
rustc=not found in default PATH
```

Before routing Rust or Swift-adjacent Linux build work there, install or expose
the needed toolchain in the non-interactive SSH environment. Keep host-specific
credentials, paths, and private topology out of this repository.
