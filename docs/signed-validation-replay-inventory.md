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
- runtime receipt identity membership.

The visual approval export for `1.0.60` is selected by the requirement and
decision set, not by a filename suffix. The retained `-final` export belongs to
a different reduced plan and must not be treated as authoritative.

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
embedded. A second recursive scan rejects absolute host paths, Apple team group
identifiers, UUID-shaped private identifiers, key material, and credential-like
strings before writing. Source paths must be normalized relative paths and may
not escape their bound root or traverse symlinks.

Never add raw runtime receipts, device inventories, launch results, provisioning
profiles, screenshots with private content, or validation containers to the
repository. The rejected `feat/simulator-first-rc-validation` working tree is
reference material only and is inadmissible as replay evidence.
