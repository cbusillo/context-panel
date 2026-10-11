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
