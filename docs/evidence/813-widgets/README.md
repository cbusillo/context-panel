# Companion widget shared-view captures (#813)

The widget continues to use the Mac's shared Horizon components and account color tokens.
All images use synthetic fixtures with a visible Sample data boundary.

- [Before: stale Medium](before-medium.png) and [after: stale Medium](after-medium.png): the host shared-view renderer, with the same fixture and appearance.
- [iPhone Medium, stale](iphone-medium-stale.png): the production shared widget rendered by the companion capture UI test on an iPhone simulator.
- [iPad Large, dense accounts](ipad-large-dense.png): the same capture UI test on an iPad simulator, in dark appearance.
- [Small, updating](small-updating.png): the host shared-view renderer preserves last-known capacity during refresh.

The simulator captures use the non-shipping XCTest/ImageRenderer mechanism described in
[the capture contract](../../signed-validation-galleries.md#private-simulator-capture).
Each simulator capture converged to two byte-identical routed PNGs. These are shared-view
captures, not home-screen placement or signed-device runtime evidence. Device delivery
and Chris's physical confirmation remain on #808 and #813.
