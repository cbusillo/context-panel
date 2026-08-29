# Signed Validation Fingerprints

Context Panel uses a reviewed surface contract to decide which signed-device
evidence must be refreshed after a change. The contract is intentionally
conservative: an input must map to at least one shipping surface, or validation
fails closed and prior approval cannot carry forward.

## Surface Inventory

`Config/ContextPanelSurfacePolicy.json` defines 13 presentation/runtime surfaces
across 11 signed artifacts:

- macOS app, widget, and refresh agent
- iPhone app and widget
- iPad app and widget
- visionOS app and widget
- watchOS app and complication
- tvOS app and Top Shelf extension

iPhone and iPad are separate presentation surfaces backed by the same iOS app
and widget artifacts. Surface IDs, not bundle IDs, are the primary keys because
several platforms intentionally reuse bundle identifiers.

The policy owns:

- source, resource, Info.plist, entitlement, CloudKit, and build-tool inputs
- target, scheme, destination, product, bundle, and embedding relationships
- archive bundle paths for each release platform
- render, runtime, placement, and shared input classifications
- evidence floors and escalation rules
- explicit developer-only inputs that do not ship

The generator also reads a normalized `project.yml` representation. Target
settings and dependency closure therefore affect only the relevant surfaces,
while global project settings remain conservatively shared.

## Fingerprints

Every surface has four SHA-256 fingerprints:

- `render`: presentation inputs plus shared inputs and target settings
- `runtime`: transport, storage, entitlement, signing-source, host-integration,
  shared inputs, and target settings
- `placement`: extension metadata and host declarations that affect OS-owned
  placement
- `combined`: render plus runtime plus placement plus the combined fingerprints
  of embedded child artifacts

Digests use a versioned domain, canonical JSON, length-prefixed fields, and
byte-sorted repository-relative paths. Absolute paths, credentials, account
identifiers, raw provider data, and App Store Connect identifiers are excluded.

The policy and fingerprint implementation produce a separate contract
fingerprint. A contract change makes prior manifests incomparable and requires
fresh evidence without falsely labeling every surface as a render change.
`Package.swift` is explicitly non-shipping: XcodeGen's `project.yml` owns the
signed artifact graph.

Run the contract gate with:

```sh
scripts/context-panel-surface-manifest.py validate
```

Generate an exact source manifest with:

```sh
scripts/context-panel-surface-manifest.py generate \
  --marketing-version 1.0.53 \
  --build-number 2026073001 \
  --commit "$(git rev-parse HEAD)" \
  --configuration Release \
  --xcode-build "$(xcodebuild -version | awk '/Build version/ { print $3 }')" \
  --tree-state clean \
  --output /tmp/context-panel-source-manifest.json
```

The legacy Mac `ContextPanelBuildFingerprint.txt` now contains the
`macos.app` combined fingerprint, preserving the canonical runtime-baseline
contract while avoiding companion-only invalidation.

## Evidence Policy

The three evidence classes are:

- `shared-view`: a human- or gallery-approved view of app-owned rendering
- `actual-runtime`: proof emitted or collected from the exact signed artifact
- `os-composited-placement`: proof of the OS-owned widget, complication, or Top
  Shelf placement

Train floors never lower change-driven requirements:

| Train   | Minimum evidence                                                 |
| ------- | ---------------------------------------------------------------- |
| Beta    | Shared view                                                      |
| RC      | Shared view and actual runtime                                   |
| Release | Shared view and actual runtime from the approved exact RC target |

Escalation rules:

- render-only change: shared-view evidence is fresh; deterministic render,
  accessibility, and simulator lanes may satisfy it without a device session
- runtime-only change: actual-runtime evidence is fresh
- placement change: actual-runtime and OS-composited placement are fresh
- unknown or unmapped change: all supported evidence classes are fresh

Exact-build runtime proof remains mandatory for RC and release trains. Beta
trains request runtime receipts only for surfaces whose runtime or placement
fingerprints changed. Comparison output includes `requiredEvidence` per surface,
class-indexed `requiredSurfaces`, `requiresRuntimeSession`, and
`requiresPlacementReview`; automation must use those fields instead of opening
an all-surface device session by default. `requiredEvidence` and
`requiredSurfaces` are the authoritative scope. `freshEvidence` explains the
delta and must not be used alone to decide whether prior approved evidence still
has to be present.

Compare two manifests with:

```sh
scripts/context-panel-surface-manifest.py compare \
  --previous previous.json \
  --current current.json \
  --train rc
```

Comparison payloads currently use schema v4. Schema v3 remains frozen in
`scripts/context_panel_surface_manifest/comparison_schema_v3.py` for archived
reconstruction, while `scripts/context_panel_comparison_schema.py` owns the
current v4 wrapper. The v4 root records `toolchainChanged`, canonical
`riskCodes`, exact `riskSurfaces`, and `observationRiskCodes`; the existing
per-surface reason and evidence fields remain unchanged.

Toolchain divergence is recorded on beta, RC, and release comparisons. Beta is
simulator-first and does not gain an actual-runtime session solely because the
Xcode build or toolchain changed. RC and release comparisons add fresh
`actual-runtime` evidence for every surface whose manifest advertises that
capability. A build-number-only change is not a toolchain risk.

The canonical root risk vocabulary is:

- `unmapped-surface`
- `render-divergence`
- `runtime-divergence`
- `placement-divergence`
- `contract-divergence`
- `toolchain-divergence`

`observationRiskCodes` contains `host-os-divergence` exactly when placement
review is required. Host OS compatibility remains owned by the release gate;
the comparison only records that the observation risk exists.

## Carry-Forward

Carry-forward is derived, never written back into prior evidence:

- shared-view evidence is eligible only when the render fingerprint is equal
- actual-runtime evidence is eligible only when the runtime fingerprint and
  exact version, build, commit, configuration, Xcode build, and tree state match
- placement evidence requires an equal placement fingerprint, the matching
  current runtime receipt, and compatible host OS evidence. A render-only change
  is re-proven through shared-view evidence and does not invalidate unchanged
  host/placement approval.

Host OS major/minor changes invalidate placement by default. Patch/build changes
are evaluated by the compositor-sensitive surface policy and active regression
watchlist. The comparison output reports these as explicit conditions rather
than assuming that a source fingerprint proves OS-owned pixels.

## Runtime Regression Watchlist

`Config/ContextPanelReleaseEvidencePolicy.json` contains the executable runtime
regression watchlist. It is a release-gate overlay, not a comparison-schema or
ledger-schema field: active entries can only add `actual-runtime`, or add both
`actual-runtime` and `os-composited-placement`, to the comparison-derived scope
for one surface. They can never remove shared-view, runtime, or placement
evidence already required by the comparison.

An entry is active while `enteredAt <= generatedAt < effectiveExpiresAt`. The
initial interval is capped at 30 days. At most two ordered extensions may be
recorded before the prior expiry, and each may add no more than 14 days. At the
exact expiry boundary the entry is inert. Extensions do not extend the 90-day
evidence-retention limit, selected-RC expiry, or carry-forward eligibility.

Entries are sorted by `surfaceId`, use bounded public-safe `reason` and
`exitCriteria` tokens, and may request only evidence supported by that surface.
There is at most one retained entry per surface. Adding, extending, replacing,
or removing an entry changes `policyDigest` and intentionally requires fresh
lineage under the new policy. Expired entries are otherwise exact gate no-ops,
including when surface capabilities later change. Gate report validation
recomputes the exact effective scope at the report's original `generatedAt`; a
broader arbitrary superset is not accepted.

## Signed Build Manifest

Every shipping Xcode target runs `scripts/stamp-context-panel-build.sh` before
code signing. A valid build embeds `ContextPanelSurfaceManifest.json`; the macOS
app also keeps the legacy text fingerprint. If the policy cannot be resolved,
ordinary compilation is not blocked: the bundle receives an `unknown` manifest.
CI and release archive validation reject that state.

The embedded manifest is deliberately minimal: manifest/contract IDs, public
bundle IDs, surface IDs, and fingerprints only. The full source-path inventory,
file hashes, commit, and ignored-input rationale remain build-system evidence
and are not shipped in App Store bundles.

Release upload scripts call
`scripts/context-panel-write-expected-build.sh` before export. It verifies every
artifact in the selected archive layout and emits
`ExpectedBuildManifest-<platform>.json` containing:

- exact version, build, commit, configuration, Xcode build, and clean-tree state
- bundle ID and per-surface render/runtime/placement/combined fingerprints
- executable SHA-256 and Mach-O UUIDs
- canonical signed-entitlement SHA-256 and provisioning-profile SHA-256 as exact
  provenance
- v2 semantic contract digests for bundle identity, signing contract, effective
  signed entitlements, and provisioning capabilities
- public signing class and canonical architecture names
- successful strict code-signature verification
- the source-manifest and expected-build IDs

Schema v2 is the current format for newly sealed expected-build manifests.
Its semantic contracts avoid printing signing material in cleartext: team IDs,
App Group values, CloudKit container IDs, certificate names, certificate
serials, profile contents, device lists, and renewal dates do not appear as raw
fields. These deterministic digests are public-safe comparison identifiers, not
confidentiality guarantees for low-entropy or externally discoverable values.
Existing schema v1 expected-build manifests remain valid for release-gate,
validation, lineage, and replay reconstruction; they are not rewritten or
interpreted as v2.

Stage 4a seals and validates this semantic provenance but does not yet widen
runtime requirements from it. Comparison schema v5 owns the later
`artifact-risk-changed` policy signal and its exact surface scope.

The embedded manifest is evidence only when it is sealed by a valid code
signature and matches the freshly generated source manifest. The archive
collector verifies both conditions; an editable JSON file by itself is not
trusted.

## Change Rules

When adding or moving shipping code:

1. Update the reviewed policy mapping.
2. Keep intentional non-shipping inputs in the pinned ignore list with a reason.
3. Run `scripts/commit-gate.sh`.
4. Review the manifest comparison before reusing prior device evidence.

Do not add generated Xcode project files, DerivedData, archives, credentials,
profiles, or runtime payloads to the source fingerprint inventory.
