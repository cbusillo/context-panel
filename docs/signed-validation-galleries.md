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

## Shared Widget Gallery

The first gallery surface reuses `ContextPanelWidgetContentView` for the small,
medium, and large widget families on macOS, iPhone, iPad, and Vision Pro. The
catalog covers:

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

## Native Routes

The Mac app exposes the gallery from Settings diagnostics. The iPhone, iPad, and
Vision Pro companion app exposes it from the navigation toolbar. Signed deep
links may select an allowlisted fixture, family, and appearance:

```text
contextpanel://validation-gallery?fixture=stale&family=systemLarge&appearance=dark
contextpanelcompanion://validation-gallery?fixture=healthy&family=systemMedium
```

Allowed query names are `fixture`, `family`, and `appearance`. Unknown,
duplicate, empty, file-based, credential-bearing, fragmented, or nested routes
are rejected. No route accepts a path, artifact, account identifier, or raw
payload.

While the gallery is visible, the host may temporarily suppress idle sleep so a
bounded review is not interrupted. The previous host setting is restored when
the gallery disappears or the scene becomes inactive. This never asks an
operator to keep a device awake while machine evidence is pending.

## Validation

Run the focused contract and render matrix:

```sh
swift test --filter 'ContextPanelCoreTests.validation'
python3 -m unittest \
  Tests/ScriptsTests/test_validation_gallery_target_graph.py
```

The bounded render matrix covers every fixture in the medium family plus small,
large, dark, and fit-fallback representatives. Companion archive validation
builds the same gallery sources for iOS and visionOS.

Gallery output is not yet a release-gate approval record. The visual approval
ledger and risk-triggered carry-forward policy remain separate coordinator and
release-integration work.
