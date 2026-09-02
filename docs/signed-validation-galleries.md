# Signed Validation Galleries

Signed validation galleries provide deterministic shared-view evidence without
changing live account data or production companion state. They render fixed
synthetic fixtures through the same value-driven SwiftUI entry points used by
shipping surfaces.

## Evidence Boundary

Gallery output is **shared-view proof**. It can show that production presentation
code handles a known state at a representative size and appearance. It cannot
prove:

- that the signed extension executed on the target device
- WidgetKit, complication, Top Shelf, or visionOS host composition
- placement margins, backgrounds, focus behavior, or other OS-owned behavior
- that a runtime receipt matches the requested release candidate

When a beta manifest comparison requires only `shared-view`, deterministic
gallery/render evidence can complete that slice without opening a device
session. It never substitutes for `actual-runtime` or
`os-composited-placement` when either appears in `requiredEvidence`.

Runtime receipts and OS-composited placement approvals remain separate evidence
classes. The gallery labels that boundary in both its persistent header and each
render tile.

## Shared-View Matrix Planning

Stage 1 defines the complete, bounded shared-view review contract in
`Config/ContextPanelSharedViewMatrix.json`. Its schema-v1 matrix covers exactly
the surfaces whose surface-policy capability includes `shared-view`, in policy
order, with two canonical representative cells per surface. Cells use only
synthetic fixture IDs and each host gallery's existing selectors: URL-route
family, appearance, and presentation values on Mac and companion hosts; Watch
complication families; and Apple TV surface and presentation modes. The
`not-applicable` sentinel marks an axis the host gallery does not expose, rather
than inventing an unreachable selector. Accessibility is explicit for every
cell.

Create schema-v1 visual-review requirements from a current schema-v5 comparison:

```sh
scripts/context-panel-validation.py plan-shared-view-evidence \
  --surface-comparison <comparison.json> \
  [--base-requirements <placement-requirements.json>] \
  --output <visual-review-requirements.json> \
  --json
```

The planner validates the comparison, surface policy, and matrix before an
atomic write. It binds `currentManifestID` to the schema-v5 comparison and emits
only cells for surfaces with fresh `shared-view` evidence. It does not create a
coordinator session, launch a simulator, install an app, read local account or
provider state, or claim runtime or placement proof. A beta comparison that has
only fresh shared-view surfaces therefore plans successfully with no runtime
surface. Mixed comparisons are accepted. When `--base-requirements` is
supplied, the planner preserves every non-shared requirement from that explicit
plan and adds the canonical matrix-bound shared-view subset. Existing
shared-view entries must already match the canonical subset exactly;
conflicting IDs, fixture contracts, manifests, or requirement bodies fail
closed. The base file is never modified in place implicitly. When placement is
fresh and no base is supplied, the command emits a warning because the
shared-only output is suitable for capture but cannot cover the combined
coordinator plan.

Each fixture contract ID is a deterministic hash over the versioned matrix
domain, complete matrix digest, relevant surface-policy contract, and canonical
cell contract. `pixelDiffPolicy` is explicitly
`advisory-only`: Stage 1 does not compare pixels or make automated approval
decisions. Private simulator capture, artifact handling, and any later capture
or approval integration remain a Stage 2 boundary.

## Private Simulator Capture

`capture-shared-view-evidence` projects the canonical shared-view subset from
the supplied requirements file, so that file may also retain placement
requirements for the coordinator. Projected IDs and requirement bodies must
exactly match the matrix planner output; placement entries are ignored by
capture and remain structurally unable to satisfy shared-view work.

The executor captures only `ios`, `ipados`, `visionos`, and `watchos` shared
app/widget-gallery requirements on throwaway simulators. It never builds,
starts a coordinator session, records a visual decision, reads runtime receipts,
or claims runtime or placement evidence.

The private schema-v1 config contains only `ios`, `ipados`, `visionos`, or
`watchos` profiles with `runtimeIdentifier`, `deviceTypeIdentifier`, and an
absolute non-symlink `appBundle`. The iPhone, iPad, and Vision profiles use the
Context Panel bundle identifier. The Watch profile must use
`com.shinycomputers.contextpanel.watch`, `WatchSimulator`, device family `4`,
a `watchOS` runtime, and an `Apple Watch` simulator device family. Every bundle
must use bounded numeric version/build values that match the source manifest,
the expected simulator platform and device family, and the exact embedded
manifest derived from the supplied canonical current source manifest. The source
manifest must use the repository policy's fixed algorithm, digest domain,
toolchain, archive layouts, evidence policy, ignored inputs, and policy digest;
self-consistent manifests in a caller-selected digest domain are rejected.

```sh
scripts/context-panel-validation.py capture-shared-view-evidence \
  --surface-comparison <comparison.json> \
  --current-manifest <current-surface-manifest.json> \
  --requirements <visual-review-requirements.json> \
  --capture-config <private-capture-config.json> \
  --artifact-root <absolute-private-artifact-root> \
  --output <absolute-shared-view-capture-receipt.json> \
  --json
```

The executor recomputes the planner output, requires exact requirements, source
manifest, embedded manifest, and captured-surface identity, then copies the app
to a private run-scoped snapshot. It hashes paths, file types, modes, and bytes,
installs only that snapshot, and verifies the installed simulator container
against the same identity except for installation-induced file-mode changes
before capture. Artifact and receipt paths must be disjoint from every input app
bundle so snapshot creation cannot recursively copy or mutate capture-owned
output.

Each simulator name is unique. A pre-create inventory blocks collisions; any
uncertain create result is cleaned only by a newly observed, profile-matching
UDID. The executor never deletes by simulator name. Each non-Watch cell resets
appearance, requires two stable pre-route baselines, then two stable decodable
routed PNGs that differ from the baseline and other cells. The Watch profile
does not call `simctl ui appearance`; it routes every app or complication cell
with the fixed argument order `simctl launch --terminate-running-process
<watch-simulator> com.shinycomputers.contextpanel.watch
--context-panel-validation-gallery --context-panel-validation-surface <surface>
--context-panel-validation-fixture <fixture>` plus
`--context-panel-validation-family <family>` for complication cells.
Watch cells retain the same baseline, stability, distinct-image, installed
identity, cleanup, artifact, and receipt checks. Termination between cells is
best-effort so one failed route cannot poison the next cell.

The Watch profile does not create or repair a paired iPhone/Watch topology. A
Watch app that cannot install independently on the selected Watch simulator, a
container identity mismatch, malformed selector, or catalog topology mismatch
is an unknown or blocked result; it never falls back to a paired simulator,
physical Watch, or changed shipping independence semantics. These captures are
shared-view artifacts only. They do not attest Watch execution and cannot prove
actual runtime behavior or a placed complication.

Runs stage under a hidden `0700` directory. PNGs, the ownership marker, and the
private index use `0600`. Publication uses exclusive no-replace renames and
parent-directory fsync before the `0644` public receipt is written; new
directory entries are also fsynced into their parents. Existing private roots
must be owned by the invoking user. PNG validation opens a bounded regular file
without following symlinks, validates chunk structure and CRCs, bounds decoded
dimensions and pixel count, and rejects oversized or trailing compressed data.
Accepted captures are non-interlaced 8-bit RGB or RGBA PNGs with only recognized
critical chunks; palette, higher-bit-depth, unknown-critical, and vendor-specific
critical encodings or transparency chunks are reported as `captured-image-invalid`.
Cleanup removes only a run whose private ownership token still matches, and a
failed emergency simulator cleanup is surfaced without exposing command output.

Mac and Apple TV remain explicit `unsupported-host-mechanism` results; missing
profiles are blocked and command, image, stability, identity, cleanup, or
publication faults are unknown. A zero exit means every requested capture was
collected. The receipt remains an artifact-collection record only and is not an
approval, runtime claim, placement claim, or pixel gate.

## Fixture Isolation

`ContextPanelValidationFixtures` is a Foundation-only target. It contains fixed
synthetic identifiers, labels, percentages, reset offsets, and prompt-cache
counts. It does not depend on `ContextPanelCore`, CloudKit, WidgetKit, app or
extension targets, stores, credentials, runtime receipts, App Group locations,
or publication APIs.

`ContextPanelValidationGalleryUI` adapts the synthetic contract into normalized
presentation models and renders them through production UI. It is linked only
into signed host apps. Widget extensions do not link either validation target.
Gallery content uses inert links and preserves normal scrolling and accessibility
inside render tiles. It cannot write snapshots, publish companion documents,
register subscriptions, record runtime receipts, or reload production timelines.

Opening a gallery does not suspend the signed host app's ordinary lifecycle.
The host may still load its live model, maintain its existing subscription, emit
its normal app runtime receipt, or refresh an existing production timeline under
the same policies used outside the gallery. Those operations never consume
fixture values and do not count as gallery evidence. The isolation guarantee is
that no fixture-derived path can cause those effects; it is not a zero-I/O app
launch mode.

The target boundary is enforced by:

```sh
python3 -m unittest \
  Tests/ScriptsTests/test_validation_gallery_target_graph.py
```

## Production Presentation Galleries

The gallery reuses production presentation symbols rather than maintaining
lookalike screens. The Mac host covers overview, account/limit detail,
reconnect, diagnostics, and widget presentations. The iPhone, iPad, and Vision
Pro host covers overview, settings, diagnostics, and widget presentations.
Production actions are disabled while a gallery preview is visible, and the
Mac fixture model uses inert refresh and runtime-receipt dependencies.

The Mac reconnect preview reuses the production reconnect layout while omitting
credential-backed account action rows. The diagnostics preview composes the
same status, alert, cache, and detail primitives used by the app rather than
initializing the live Settings model. Those boundaries keep fixture values from
reaching credential, bookmark, notification, or App Group stores.

The shared widget presentation reuses `ContextPanelWidgetContentView` for the
small, medium, and large widget families on macOS, iPhone, iPad, and Vision Pro.
The catalog covers:

- healthy multi-provider capacity
- reset pressure
- prompt-cache visibility
- stale last-good data
- refresh-in-progress data
- missing/setup state
- failed refresh with last-good values
- dense multi-account data
- long-label fit fallbacks

Every account identifier and label is synthetic and uses the `sample-` / `Sample
` naming boundary. Email-shaped labels and production-derived values are not
allowed.

The fixture catalog owns one fixed reference presentation time. Widget reset and
relative date helpers consume that injected time so repeated captures do not
change across launches or at a minute boundary while they are being reviewed.

## Operator Routes

Normal product UI does not expose Validation Gallery buttons, toolbar actions,
list rows, or runway items. Signed-validation operators open the Mac, iPhone,
iPad, Vision Pro, and Apple TV galleries through allowlisted deep links. The
routes may select a fixture, family, appearance, and presentation:

```text
contextpanel://validation-gallery?fixture=stale&appearance=dark&presentation=diagnostics
contextpanelcompanion://validation-gallery?fixture=healthy&presentation=settings
```

Allowed query names are `fixture`, `family`, `appearance`, and `presentation`.
Unknown, duplicate, empty, file-based, credential-bearing, fragmented, or
nested routes are rejected. No route accepts a path, artifact, account
identifier, or raw payload. These routes are operator tooling, not normal
product navigation. Hosts expose only the presentations that exist on that
platform.

While the gallery is visible, the host may temporarily suppress idle sleep so a
bounded review is not interrupted. The previous host setting is restored when
the gallery disappears or the scene becomes inactive. This never asks an
operator to keep a device awake while machine evidence is pending.

## Watch Gallery

The signed Watch app does not expose gallery navigation during normal use.
Operators launch the installed app with the allowlisted
`--context-panel-validation-gallery` argument through `devicectl`. App-state
previews reuse the same status, forecast, provider-access, empty-state, and
limit-row presentation used by the live Watch screen. Circular, rectangular,
inline, and corner previews compile the same complication family dispatcher
source as the shipping WidgetKit extension. The gallery uses reference-size
canvases; WidgetKit supplies exact face dimensions and the corner gauge/label
only to a placed complication.

```sh
xcrun devicectl device process launch \
  --device <watch-device> \
  com.shinycomputers.contextpanel.watch \
  --context-panel-validation-gallery
```

The gallery route never instantiates the live loader, cache, CloudKit stores,
runtime-receipt relay, or timeline reload path. In the shared Watch widget
source, an extension-only compilation boundary keeps the live timeline provider,
runtime-receipt recorder, widget registration, and WidgetBundle entry point out
of the Watch app target. The normal Watch root retains its live sync behavior
outside the gallery. A persistent `Sample data` boundary stays above every
gallery screen. Gallery output remains shared-view proof; the installed-build
Watch restart and real placed-complication glance remain required whenever
complication host behavior changed.

## Apple TV Gallery

The signed Apple TV app does not expose gallery navigation in the production
runway. The bounded `contextpaneltv://validation-gallery` operator route opens
the signed destination for simulator and device review. Runway and
provider-detail previews instantiate the same `TVRunwayContent` and
`TVProviderDetailView` presentation used by the live app, with a fixed
presentation date and a local `@State` presentation-mode picker.

Top Shelf previews call the shipping renderer's in-memory image path with the
same `TVTopShelfDocument` model used by the extension. The app compilation path
does not include the extension-only provider, App Group document/image cache,
runtime-receipt recorder, `setImageURL` calls, or
`topShelfContentDidChange()` publication. A persistent `Sample data · Read
only` banner remains above every preview.

The Top Shelf image is shared-renderer proof, not TVServices composition proof.
Real Top Shelf placement, host scaling, focus/parallax, expiration behavior,
deep links, and installed-build typography still require the Apple TV glance
when those host behaviors changed.

## Validation

Run the focused contract and render matrix:

```sh
swift test --filter 'ValidationGallery|ValidationFixtures|validationGallery|validationFixture'
python3 -m unittest \
  Tests/ScriptsTests/test_validation_gallery_target_graph.py
scripts/validate-companion-builds.sh --configuration Release --archive tvos
```

The bounded render matrix covers every fixture in the medium family plus small,
large, dark, fit-fallback, accessibility-size, Mac production-presentation, and
no-fixture-write representatives. Companion archive validation builds the same
gallery sources for iOS and visionOS.

Gallery output becomes a coordinator approval record only when an explicit
shared-view requirement binds the fixture/gallery contract digest, presentation
context, exact render fingerprint, and human decision. The ledger never upgrades
gallery output into OS-composited placement proof. Risk-triggered carry-forward
remains separate release-integration work.
