# Horizon screenshot candidates

Prepared for [#744](https://github.com/cbusillo/context-panel/issues/744),
October 11, 2026. **Draft, unapproved, repo only.**

These PNGs render the current production Horizon SwiftUI panels using made-up
accounts through `ContextPanelSharedViewRenderer`. They are host-rendered
compositions, not screenshots of complete platform apps, placed widgets, or
physical devices. They carry no signed-build, runtime, placement, or release
approval. The Watch image isolates one account row and omits the overview
headline and deadline list. Mac detail omits the sidebar; companion panels omit
navigation, sync status, and OS chrome. Vision Pro has a flat background rather
than spatial composition. Compact detail text retains the production view's
truncation; the smaller iPhone canvas also clips the bottom of the banked-reset
card. Review those limitations before choosing any image for the store.
The Mac widget composition is magnified at 2 pixels per point on its canvas,
while the Mac detail panel uses 1 pixel per point; their apparent sizes differ.

The fixture is pinned to October 1, 2026 at 2:07 PM UTC. Studio, Work, Personal,
Claude primary, Claude backup, and Antigravity are synthetic labels. No account
storage, credentials, live provider data, or CloudKit records are read.

## Review images

Dimensions and checksums are recorded only in [manifest.json](manifest.json).
Target dimensions were checked against
[Apple's screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
on October 11, 2026. Matching dimensions establishes a candidate canvas; it
does not establish App Review acceptance of rendered compositions.

| Intended display | Surface | Light | Dark |
| --- | --- | --- | --- |
| Mac / APP_DESKTOP | Account detail panel | [Image](mac-detail-light.png) | [Image](mac-detail-dark.png) |
| Mac / APP_DESKTOP | Large widget composition | [Image](mac-widget-light.png) | [Image](mac-widget-dark.png) |
| iPhone / APP_IPHONE_61 | Compact account detail panel | [Image](iphone-detail-light.png) | [Image](iphone-detail-dark.png) |
| iPhone / APP_IPHONE_65 | Compact account detail panel | [Image](iphone65-detail-light.png) | [Image](iphone65-detail-dark.png) |
| iPad / APP_IPAD_PRO_3GEN_129 | Overview panel | [Image](ipad-overview-light.png) | [Image](ipad-overview-dark.png) |
| Vision Pro / APP_APPLE_VISION_PRO | Overview composition | [Image](visionpro-overview-light.png) | [Image](visionpro-overview-dark.png) |
| Watch / APP_WATCH_ULTRA | Isolated account row | — | [Image](watch-account-dark.png) |
| Apple TV / APP_APPLE_TV | Account board | — | [Image](tvos-board-dark.png) |

The uploader still selects the approved historical paths listed in the parent
[matrix](../screenshot-matrix.md). Approval and any later upload are separate
work. The issue's original finish line remains open. If complete app or
OS-composited captures are required, collect those through the supported
[capture mechanisms](../../../../docs/signed-validation-galleries.md) and the
canonical Mac runtime rules, then replace the affected candidates after review.
Do not treat these files as formal capture receipts.

## Reproduce

Build the renderer from this PR's checkout with:

```sh
swift build --product ContextPanelSharedViewRenderer --scratch-path .build/screenshot-renderer
```

For each asset, pass `rendererBaseArguments` from the manifest, then its
`--presentation`, `--family`, `--appearance`, and `--scale` values. Set
`--output` to a fresh scratch path; the renderer refuses to overwrite images.
For example:

```sh
.build/screenshot-renderer/debug/ContextPanelSharedViewRenderer \
  --fixture healthy --scenario app-store --presentation phone-detail \
  --family systemLarge --appearance light --scale 3 --output /absolute/scratch/phone.png
```

For assets with `padding`, center the raw render on the recorded height/width
canvas with `sips --padToHeightWidth HEIGHT WIDTH --padColor COLOR INPUT --out OUTPUT`.
Use the asset's `paddingColor` from the manifest, matched to the rendered
surface color. The padding adds a flat background;
it does not resize, crop, or retouch the rendered UI. Record hashes of the final
PNG bytes. Host OS/fonts can affect bytes on another machine.

`productSourceCommit` identifies the unchanged shipping view source used for
this set. `rendererSourceSHA256` is SHA-256 of the exact bytes of
`Tools/ContextPanelSharedViewRenderer/main.swift` used to generate the images.
Verify it directly when reproducing; tests check real image artifacts rather
than Swift source text. Existing validation fixture scenarios and their canvas sizes are
preserved; the `app-store` scenario is for these draft assets only.
