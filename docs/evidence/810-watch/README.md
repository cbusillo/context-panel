# Watch design and simulator evidence

`before-design.png` and `proposed-design.png` are a synthetic native SwiftUI
hierarchy study at 198 points, rendered on the host. The proposed study uses a
simple remaining-capacity bar; implementation retains the shared Watch Horizon.

`before/` contains baseline watchOS 27 simulator captures on a 42 mm Watch.
They use the existing operator-only gallery with synthetic fixtures. The baseline
gallery exercises legacy limit UI because its snapshots have no account metadata.

These are shared-view artifacts, not signed runtime, sync, physical Watch, or
OS-composited complication placement evidence. #808 owns device delivery and
#810 remains open until Chris accepts the matching build on his Watch.

`after/app-42mm.png`, `circular-42mm.png` and `rectangular-42mm.png` are final
watchOS 27 simulator gallery screenshots, built from this task's source. These
exercise account adaptation; the rectangular gallery uses the shared renderer's
74-point reference height. WidgetKit sets the actual placed-face canvas.

The `row-*` images are host `ImageRenderer` captures of the production shared
Watch views, at 198 points with synthetic long names, Saved and unknown readings.
They show wrapping and capacity semantics, not watchOS text scaling or placement.
The operator capture shell is temporary and does not ship in the app.
