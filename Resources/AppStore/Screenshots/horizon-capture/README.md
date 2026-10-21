# Horizon app capture preparation

Prepared for [#744](https://github.com/cbusillo/context-panel/issues/744),
October 20, 2026, CP744-C2. **Incomplete, unapproved, repo only.**

The four Mac images include the production account sidebar, overview,
account detail and native AppKit title bar/window controls. They use six synthetic accounts through the offscreen SwiftUI
renderer. They capture a complete inactive window frame offscreen, without
a desktop, actual WidgetKit placement or signed-runtime evidence. No normal Mac app is launched;
the renderer creates an AppKit window hierarchy that is never ordered onto a
display. The native frame is rendered as AppKit views, not through screen capture or
the WindowServer compositor. The composition uses the production sidebar, overview and account-detail
components, including the account diagnostics disclosure. It has no lifecycle
tasks or account/provider refresh.

| Mac window | Light | Dark |
| --- | --- | --- |
| Overview and sidebar | [Image](mac-overview-light.png) | [Image](mac-overview-dark.png) |
| Studio account and sidebar | [Image](mac-detail-light.png) | [Image](mac-detail-dark.png) |

Dimensions, checksums and rendering provenance are recorded once in
[manifest.json](manifest.json). All four images are opaque 2880 × 1800 PNGs.
They were visually checked for the sidebar, forecast, account identity,
capacity numbers, clipping and contrast. App Store dimensions were checked
against [Apple's specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/).
Matching dimensions does not establish approval of rendered app compositions.

The [earlier 14-image draft](../horizon-draft/README.md) remains available for
comparison. Neither set changes the approved uploader mapping.

## Remaining captures

| Platform/surface | Current evidence | Remaining work |
| --- | --- | --- |
| Mac app | Four offscreen native-frame images above | Chris reviews the concrete images; no desktop/WidgetKit placement proof |
| Mac widgets | Earlier draft compositions only | Actual WidgetKit placement in an isolated fixture environment; never Chris's desktop |
| iPhone and iPad app | Capture-only iOS simulator build passed | Private-storage iPhone fixture launch passed; approved stdout attempt was denied too. Capture native navigation at both iPhone sizes and iPad size |
| iPhone/iPad widgets | Earlier draft covers no placed widgets | Capture actual widget placement in owned fixture simulators; the tool does not yet automate placement |
| Watch app | Capture-only watchOS simulator build passed | Launch/capture native navigation, status, headline and account list |
| Vision Pro app | Capture-only visionOS simulator build passed | Capture spatial app context; framebuffer capture may omit spatial windows and cannot be assumed sufficient |
| Vision Pro widgets | Earlier flat compositions only | Actual spatial WidgetKit placement; no compositor or placement proof from a shared-view renderer |
| Apple TV app | Capture-only tvOS simulator build passed | Launch/capture full native overview including controls, status and account groups |

[Q599 approved private CoreSimulator storage](https://github.com/cbusillo/context-panel/issues/744#issuecomment-6305613280),
and [Q602 approved stdout PNG transport](https://github.com/cbusillo/context-panel/issues/744#issuecomment-6306472402).
The first approved stdout invocation still failed: the installed CLI treated
`-` as a filename in the external worktree and returned a file-write permission
denial (`NSCocoaErrorDomain 513`, `NSPOSIXErrorDomain 1`). No PNG was produced.
**Capture is stopped again.** [Q605](https://github.com/cbusillo/context-panel/issues/744#issuecomment-6306623312)
owns the exact failure, read-only investigation and the proposed recovery. No other backend, descriptor type or
staging route may be tried without the recorded recovery decision. This is
separate from later image approval. The created simulator was deleted and
absence verified; all 31 pre-existing devices remain.

Mac desktop WidgetKit placement cannot be supplied by this offscreen tool.
Do not use Chris's live desktop to fill that gap. If no isolated repository
capture route can supply it, post the exact needed fixture-only manual capture
as an Owner question on #744 before proceeding. The same applies if visionOS
spatial composition needs a live Simulator window on his desktop.

## Reproduce

From a clean committed source tree on a host whose OS/fonts match the manifest:

```sh
swift build --product ContextPanelAppStoreCapture --scratch-path .build/app-store-capture
.build/app-store-capture/debug/ContextPanelAppStoreCapture overview light /absolute/new/mac-overview-light.png
.build/app-store-capture/debug/ContextPanelAppStoreCapture overview dark /absolute/new/mac-overview-dark.png
.build/app-store-capture/debug/ContextPanelAppStoreCapture detail light /absolute/new/mac-detail-light.png
.build/app-store-capture/debug/ContextPanelAppStoreCapture detail dark /absolute/new/mac-detail-dark.png
```

The renderer refuses existing output files. Its fixture uses no credentials,
account homes, saved production snapshots or CloudKit. Dates are pinned to the
manifest's fixture time in UTC and US English. Changes in macOS fonts or
AppKit may change the PNG bytes; record the resulting bytes rather than
claiming cross-host byte identity.

The simulator tool prepares a separate generated project in `.build`, retaining
only the three capture apps and their static-library dependencies. It discards
shipping configuration/signing overrides, unused extension targets and their
source-tree plist generation. The project has
unique capture-only bundle identifiers, a watch-only capture plist, no
entitlements, no embedded extensions, no build-manifest stamping and the `CONTEXT_PANEL_SCREENSHOTS`
compilation condition. The shipping project never sets that condition or
includes the capture fixture source. In capture mode the companion's normal
root, navigation and layout receive an in-memory fixture; its app delegate,
stores, runtime receipts, CloudKit subscription and reload are disabled. Watch
and TV reuse the production content and navigation with inert actions.
The fixture initializes UTC and US English in each capture process before views
or models are constructed. Mac and simulator date formatting use the same clock
and timezone. Normal shipping launch paths remain intact. Prepare and build require a clean
committed source tree. Each build records its commit and complete bundle digest;
capture refuses a different commit, dirty source or altered bundle. If source
changes, run prepare and the relevant build again.

```sh
uv run scripts/capture-app-store-screenshots.py prepare
uv run scripts/capture-app-store-screenshots.py build ios
uv run scripts/capture-app-store-screenshots.py build watchos
uv run scripts/capture-app-store-screenshots.py build tvos
uv run scripts/capture-app-store-screenshots.py build visionos
```

The command below records the approved stdout attempt. It failed on this
host. Do not rerun capture before the recorded Q605 recovery decision:

```sh
uv run scripts/capture-app-store-screenshots.py capture iphone --output /absolute/new/iphone
```

Other profiles are `iphone65`, `ipad`, `watch`, `visionpro` and `tvos`. Each run
owns a newly named simulator and records the returned UDID, built source commit and bundle digest,
runtime, device type, image dimensions and checksums. The built source owns the
fixture date and timezone; the Python tool does not copy those values. Cleanup
uses the UDID returned by successful creation. If creation fails without a
returned UDID, it reconciles only a newly observed exact name/type/runtime match.
A returned pre-existing UDID is refused before boot/install or cleanup. The tool
verifies the owned UDID is absent before recording success. Cleanup failures retain the primary capture error with an added diagnostic;
uncertain ownership preserves candidates and fails the command. A successful
framebuffer PNG still needs visual
review, particularly on visionOS. Captures are not formal release receipts.
No uploader or App Store submission is called by this tool.
