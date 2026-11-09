# Build Fingerprints

Every shipping build carries per-surface fingerprints of the source that made
it. The upload scripts check the signed bundles against them, and the runtime
baseline uses the Mac app's fingerprint to tell whether the installed app is
this checkout. The contract is conservative: an input must map to at least one
shipping surface, or the commit gate fails.

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
fingerprint. `Package.swift` is explicitly non-shipping: XcodeGen's `project.yml` owns the
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

## Signed Build Manifest

Every shipping Xcode target runs `scripts/stamp-context-panel-build.sh` before
code signing. A valid build embeds `ContextPanelSurfaceManifest.json`; the macOS
app also keeps the legacy text fingerprint. If the policy cannot be resolved,
ordinary compilation is not blocked: the bundle receives an `unknown` manifest.
CI and release archive validation reject that state.

The embedded manifest is deliberately minimal: manifest/contract IDs, public
bundle IDs, surface IDs, and fingerprints only. The full source-path inventory,
file hashes, commit, and ignored-input rationale stay in the build system and
are not shipped in App Store bundles.

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

The embedded manifest is trusted only when it is sealed by a valid code
signature and matches the freshly generated source manifest. The archive
collector verifies both conditions; an editable JSON file by itself is not
trusted.

## Change Rules

When adding or moving shipping code:

1. Update the reviewed policy mapping.
2. Keep intentional non-shipping inputs in the pinned ignore list with a reason.
3. Run `qualityGate.validate.surfaceFingerprintContract` and
   `surfaceFingerprintTests` from `.github/github.json`; the full gate runs in CI.

Do not add generated Xcode project files, DerivedData, archives, credentials,
profiles, or runtime payloads to the source fingerprint inventory.
