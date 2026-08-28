# Signed Validation Replay Inventory

The replay inventory records which retained signed artifacts can support
historical validation claims. It stores only content digests, bounded enums,
targets, and symbolic root-relative paths. It never stores absolute paths,
device identifiers, raw runtime receipts, approval bodies, credentials, or
provider data.

The source-of-truth policy is
`Config/ContextPanelReplayInventoryPolicy.json`. The generated public-safe
inventory is
`scripts/context_panel_replay/inventory/signed-trains.json`.

## Evidence Tiers

The inventory separates two different reproducibility claims:

- The committed inventory can be checked offline in CI, including its policy
  binding, train coverage, category coverage, self-digest, and public-safety
  contract.
- An operator with the retained private roots can re-seal the inventory and
  require byte-identical output.

The second check proves that the committed digests still match retained raw
artifacts. The raw artifacts remain private and are never copied into the
repository. Content-derived counts and digests are attested by private-root
`verify`; the offline check validates their schema and internal invariants.

## Source Roots

Private roots are always supplied explicitly as `ROOT_ID=ABSOLUTE_PATH`.
There are no discovery defaults, environment fallbacks, or implicit probes of
Application Support, `.build`, `.code`, group containers, or live coordinator
state.

The committed policy uses these symbolic roots:

- `shadow-trains`: retained signed-train exports in the durable validation
  archive.
- `build-release-evidence`: ignored and wipe-eligible release evidence.
- `code-evidence`: ignored and wipe-eligible local validation evidence.

Absolute root values are consumed during sealing and discarded. The generated
inventory contains only the symbolic root and reviewed relative path.

## Commands

Run the offline check from any checkout:

```sh
scripts/context-panel-replay-inventory.py check --json
```

Seal or verify with all policy roots bound explicitly:

```sh
scripts/context-panel-replay-inventory.py seal \
  --root shadow-trains=<absolute-shadow-trains-root> \
  --root build-release-evidence=<absolute-release-evidence-root> \
  --root code-evidence=<absolute-code-evidence-root> \
  --json

scripts/context-panel-replay-inventory.py verify \
  --root shadow-trains=<absolute-shadow-trains-root> \
  --root build-release-evidence=<absolute-release-evidence-root> \
  --root code-evidence=<absolute-code-evidence-root> \
  --json
```

`verify` re-derives the complete inventory and compares its rendered bytes with
the committed file. Formatting changes, stale digests, changed policy, missing
files, or altered evidence fail closed.

## Selection And Binding

The policy names reviewed source locators, but the tool independently validates
their evidence chain:

- ledger self-digest;
- lineage ledger equality;
- comparison and final-report digests;
- previous and current source-manifest IDs;
- policy-pinned manifest, contract-fingerprint, and required-surface metadata;
- expected-build manifest set and target identity;
- final-report target;
- visual approval requirement and decision set;
- runtime receipt identity membership, with retained bodies required to
  reproduce their cited IDs and current train build identity.

The visual approval export for `1.0.60` is selected by the requirement and
decision set, not by a filename suffix. The retained `-final` export belongs to
a different reduced plan and must not be treated as authoritative.

## Comparison Schema Compatibility

Production comparison generation, coordinator planning, direct release-gate
inputs, report validation, and submission accept only schema v3. Schema v3 adds
the canonical `runtimeState` and `runtimeStateReasons` decision contract without
changing the current evidence floors. Retained v1 comparisons are replay-only:
inventory lineage validation verifies the raw archived chain before the adapter
deep-copies the v1 payload, injects its frozen v2 identity, and validates with
the pinned reconstruction contract. Retained v2 comparisons validate directly
against that same frozen v2 contract. Release-gate lineage reconstruction may
validate embedded signed v1 or v2 comparisons while preserving their raw
comparison digests; those exceptions are unavailable to direct production
inputs.

The v1 adapter verifies its contract, implementation, and transitive dependency
digests at runtime. The exact schema v2 validator is retained in
`scripts/context_panel_surface_manifest/comparison_schema_v2.py`; production v3
and historical v1/v2 reconstruction share that frozen implementation rather
than re-baselining the adapter. Any source, dependency, or contract behavior
change requires an explicit adapter version and fixture/digest update; do not
route retained replay through a future current-schema validator. Its legacy exceptions preserve
historical carry-forward map insertion order and incomplete maps present in the
retained v1 corpus; production v3 rejects both forms.

## Recoverability

Every input has one recoverability class:

- `durable`: redundant retained copies exist.
- `single-copy`: one copy exists in a durable retained root.
- `fragile`: the retained copy exists only in an ignored, wipe-eligible root.
- `reference-only`: the body is gone, but the signed final report or ledger
  retains its identity set.

The inventory is intentionally honest about retained gaps:

- `1.0.57` and `1.0.60` runtime receipt bodies expired; only their signed
  receipt identity sets remain.
- The final `1.0.61` tvOS beta slice retains most receipt bodies, but one cited
  body is absent.
- The predecessor source manifest for that `1.0.61` slice is fragile because
  its only retained copy is in the ignored release-evidence root.

These conditions produce machine-readable residual risks and restrict later
replay claims. Reference-only evidence can support identity-set replay, not raw
receipt-body replay. The `1.0.61` beta slice cannot qualify an RC or release.

## Public Safety

The serializer is construction-based: raw JSON bodies are hashed and never
embedded. A second recursive scan rejects absolute host paths (including
`file:///...` URLs), UUID-shaped private identifiers, key material, and
credential-like strings, including Apple team-prefixed app-group identifiers,
before writing. Public app-group identifiers are not treated as secrets by the
physical defect corpus validator. Source paths must be
normalized relative paths and may not escape their bound root or traverse
symlinks.

Never add raw runtime receipts, device inventories, launch results, provisioning
profiles, screenshots with private content, or validation containers to the
repository. The rejected `feat/simulator-first-rc-validation` working tree is
reference material only and is inadmissible as replay evidence.

## Signed Train Replay

Issue #609 adds sidecar replay without changing release decisions. Tier B
rechecks the three-root projection; Tier A freezes it and derives the report.
`check` and `verify` are gates; reference-only evidence stays
`sources-unverified`.

## Physical Defect Corpus

`Config/ContextPanelPhysicalDefectCorpus.json` is a separate, versioned,
declarative replay-only corpus for physical-hardware defects. It does not feed
the production manifest comparator, release gate, or surface-policy resolver.
Each confirmed public-record incident binds its positive input to the exact
implementation commit that is the second parent of its cited pull-request
merge. Candidate policies use strict changed-path and diff-content regex
matchers against those historical diffs; the compiler derives every positive
path and patch digest rather than accepting curator-authored positive paths.
Each incident also carries one same-surface negative near-miss as a full
historical commit evaluated by the same policy. Near-miss boundaries derive
their baseline evidence from the surface policy and must reduce physical
evidence burden rather than claiming that a behavioral change needs no
evidence. A required rationale explains why the historical change is similar
but outside the incident signature, and compiled output records whether the
control rejected at path or content matching. Evidence class and provenance are distinct:
shared-view evidence may come from a deterministic gallery or an exact physical
build, and neither is placement evidence.

The compiler accepts only compact public-safe descriptors, validates exact
pull-request citation objects (number, merge commit, and implementation commit)
against the local repository, and requires every cited commit to be an ancestor
of the curation cutoff. Historical diffs, repository anchors, and the surface
policy are all resolved from that cutoff rather than mutable `HEAD` or worktree
state. It rejects absolute paths after punctuation, file URLs, standard bearer
or basic authorization values, labeled credentials, high-confidence standalone
provider tokens, email-like and provider account identifiers, UUIDs,
device-specific data, and raw receipt fields. The same scan runs against
compiled output, which keeps only derived paths and digests, never raw patches.
Historical citation validation requires complete Git history, so CI checks out
with `fetch-depth: 0`. The source pins the Git compiler to `2.55.0`; fork CI
downloads the checksum-pinned upstream source archive and builds that exact
compiler, while every runner reports installed and required versions on a
mismatch. The compiler uses a scrubbed environment plus explicit diff,
signature, path-order, and attribute settings. Unsupported, over-triggered,
unrepresented, and live-policy-drift coverage remain residual risks rather
than invented positives. Corpus evidence expectations stay bound to the
curation-cutoff policy; operators must compare live evidence semantics before
generalizing historical replay results.

Run the deterministic offline check with:

```sh
python3 scripts/context-panel-defect-corpus.py check --json
```

Regenerate the committed artifact only after review:

```sh
python3 scripts/context-panel-defect-corpus.py generate --json
```

`scripts/context_panel_replay/corpus/compiled.json` must reproduce byte-for-byte
from the curated source and the surface policy at the declared curation cutoff.
The focused corpus tests run in the safe `fast-local-python` lane.
