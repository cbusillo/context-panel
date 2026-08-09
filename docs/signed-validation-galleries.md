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
