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
| iPhone and iPad app | Capture-only iOS simulator build passed | Private-storage fixture launch passed; Q605 temp staging is implemented. Capture native navigation at both iPhone sizes and iPad size |
| iPhone/iPad widgets | Earlier draft covers no placed widgets | Capture actual widget placement in owned fixture simulators; the tool does not yet automate placement |
| Watch app | Capture-only watchOS simulator build passed | Launch/capture native navigation, status, headline and account list |
| Vision Pro app | Capture-only visionOS simulator build passed | Capture spatial app context; framebuffer capture may omit spatial windows and cannot be assumed sufficient |
| Vision Pro widgets | Earlier flat compositions only | Actual spatial WidgetKit placement; no compositor or placement proof from a shared-view renderer |
| Apple TV app | Capture-only tvOS simulator build passed | Launch/capture full native overview including controls, status and account groups |

[Q605's exact decision](https://github.com/cbusillo/context-panel/issues/744#issuecomment-6307013529)
authorizes a simpler capture path: `mktemp -d` in the system temp directory,
normal PNG file output, validation/copy to Developer-Artifacts, then removal of
the temp file and folder. Only a refused temp screenshot save permits the
approved fallback to a fresh directory inside the owned fixture-app container.
Any other refusal stops. There is no stdout transport or persistent internal
image directory. Earlier failed attempts and decisions remain on #744.
Both staging routes delete only their own PNG and newly created empty folder;
owned-simulator cleanup still verifies absence before recording success.

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

Use only this fixture-only capture command and the Q605 staging order:

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
