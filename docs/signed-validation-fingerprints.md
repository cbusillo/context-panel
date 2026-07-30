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
- render, runtime, and shared input classifications
- evidence floors and escalation rules
- explicit developer-only inputs that do not ship

The generator also reads a normalized `project.yml` representation. Target
settings and dependency closure therefore affect only the relevant surfaces,
while global project settings remain conservatively shared.

## Fingerprints

Every surface has three SHA-256 fingerprints:

- `render`: presentation inputs plus shared inputs and target settings
- `runtime`: transport, storage, entitlement, signing-source, host-integration,
  shared inputs, and target settings
- `combined`: render plus runtime plus the combined fingerprints of embedded
  child artifacts

Digests use a versioned domain, canonical JSON, length-prefixed fields, and
byte-sorted repository-relative paths. Absolute paths, credentials, account
identifiers, raw provider data, and App Store Connect identifiers are excluded.

The policy and fingerprint implementation are themselves shared inputs. A
change to the mapping or algorithm therefore invalidates every surface rather
than silently reinterpreting prior approvals.

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

- render change: all supported evidence classes are fresh
- runtime-only change: actual-runtime evidence is fresh
- unknown or unmapped change: all supported evidence classes are fresh

Compare two manifests with:

```sh
scripts/context-panel-surface-manifest.py compare \
  --previous previous.json \
  --current current.json \
  --train rc
```

## Carry-Forward

Carry-forward is derived, never written back into prior evidence:

- shared-view evidence is eligible only when the render fingerprint is equal
- actual-runtime evidence is eligible only when the runtime fingerprint and
  exact version, build, commit, configuration, Xcode build, and tree state match
- placement evidence additionally requires the matching current runtime receipt
  and compatible host OS evidence

Host OS major/minor changes invalidate placement by default. Patch/build changes
are evaluated by the compositor-sensitive surface policy and active regression
watchlist. The comparison output reports these as explicit conditions rather
than assuming that a source fingerprint proves OS-owned pixels.

## Signed Build Manifest

Every shipping Xcode target runs `scripts/stamp-context-panel-build.sh` before
code signing. A valid build embeds `ContextPanelSurfaceManifest.json`; the macOS
app also keeps the legacy text fingerprint. If the policy cannot be resolved,
ordinary compilation is not blocked: the bundle receives an `unknown` manifest.
CI and release archive validation reject that state.

Release upload scripts call
`scripts/context-panel-write-expected-build.sh` before export. It verifies every
artifact in the selected archive layout and emits
`ExpectedBuildManifest-<platform>.json` containing:

- exact version, build, commit, configuration, Xcode build, and clean-tree state
- bundle ID and per-surface render/runtime/combined fingerprints
- executable SHA-256 and Mach-O UUIDs
- canonical signed-entitlement SHA-256
- embedded provisioning-profile SHA-256
- successful strict code-signature verification
- the source-manifest and expected-build IDs

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
