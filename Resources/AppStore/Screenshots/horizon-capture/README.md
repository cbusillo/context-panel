# Horizon native app and widget review set

Prepared for [#744](https://github.com/cbusillo/context-panel/issues/744),
October 21, 2026, CP744-C2. **Complete set of 27 unapproved images.
No ready, App Store upload or submission.**

These images show the native Horizon apps with synthetic account data. Mac app
images are XCTest screenshots of complete native windows on an isolated
GitHub-hosted Mac. iPhone, iPad, Watch and TV images include native navigation
and system chrome in owned simulators. Vision Pro images include the actual
spatial app window in the simulator's stock room environment.

| Platform and scene | Light | Dark |
| --- | --- | --- |
| Mac overview and sidebar | [Image](mac-overview-light.png) | [Image](mac-overview-dark.png) |
| Mac Studio account and sidebar | [Image](mac-detail-light.png) | [Image](mac-detail-dark.png) |
| Mac actual desktop widgets, small, medium and large | [Image](mac-widget-desktop.png) | — |
| iPhone 17 Pro, Dynamic Island medium display, overview | [Image](iphone-overview-light.png) | [Image](iphone-overview-dark.png) |
| iPhone 17 Pro, Dynamic Island medium display, Studio detail | [Image](iphone-detail-light.png) | [Image](iphone-detail-dark.png) |
| iPhone 17 Pro, Dynamic Island medium display, actual Home Screen widget | [Image](iphone-widget-light.png) | [Image](iphone-widget-dark.png) |
| iPhone 14 Plus, Face ID large display, overview | [Image](iphone65-overview-light.png) | [Image](iphone65-overview-dark.png) |
| iPhone 14 Plus, Face ID large display, actual Home Screen widget | [Image](iphone65-widget-light.png) | [Image](iphone65-widget-dark.png) |
| iPad overview | [Image](ipad-overview-light.png) | [Image](ipad-overview-dark.png) |
| iPad Studio detail | [Image](ipad-detail-light.png) | [Image](ipad-detail-dark.png) |
| iPad actual Home Screen widget | [Image](ipad-widget-light.png) | [Image](ipad-widget-dark.png) |
| Watch overview and deadlines | — | [Image](watch-overview-dark.png) |
| Watch Studio account card | — | [Image](watch-accounts-dark.png) |
| Vision Pro spatial overview | — | [Image](visionpro-overview-dark.png) |
| Vision Pro spatial Studio detail | — | [Image](visionpro-detail-dark.png) |
| Vision Pro actual spatial widget and app | — | [Image](visionpro-widget-dark.png) |
| Apple TV native Accounts board | — | [Image](tvos-overview-dark.png) |

[manifest.json](manifest.json) records every image's dimensions, SHA-256,
source commit and capture mechanism. The [screenshot matrix](../screenshot-matrix.md)
contains the image links and checksums together. All selected files are RGB
PNGs without an alpha channel. Removing an opaque alpha channel preserves
all RGB pixels and the source ICC profile; transparent inputs are refused.
Dimensions and current display-group names were checked on October 21, 2026
against [Apple's screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/).
The `iphone65` file slug retains the earlier uploader terminology; the actual
capture device is iPhone 14 Plus. Uploader mappings remain unchanged.

The fixture has six synthetic accounts across OpenAI, Anthropic and Google.
Its presentation clock, locale and timezone come from
[the fixture source](../../../../Tools/ContextPanelAppStoreCapture/ScreenshotFixture.swift).
System status indicators belong to the isolated capture environment. No real
account, credential, saved production snapshot, CloudKit subscription or
provider refresh supplies these images. They are image review evidence, not
signed-runtime or physical-device qualification.

Rejected Home-screen samples, incomplete Mac crops and failed capture runs are
excluded. Every selected image was checked for the intended native screen,
forecast and account text, clipping, contrast and OS context. Vision Pro uses
one app-owned dark appearance; duplicate light-labelled frames are excluded.

Never use Chris's running apps, desktop, browser or real account data for
recaptures. If a capture can only use his live desktop, stop and post an
Owner question on #744 describing exactly what is needed. Any new permission
or authorization refusal stops and is reported on #744.

## Capture tooling

The repository tool generates a separate Xcode project under `.build`, with
capture-only bundle identifiers and synthetic fixtures. Shipping entitlements,
embedded shipping extensions, account stores and build stamping are excluded.
iOS and Vision Pro have app-associated capture UI tests. The shipping project
does not set
`CONTEXT_PANEL_SCREENSHOTS` or include the fixture sources.

Prepare, build and capture require a clean committed tree and share one lock.
A build receipt binds the source and complete app bundle digest; iOS also binds
the test runner and original test-run configuration. The tool checks those
products before and after capture. It creates one uniquely named simulator,
uses only its returned UUID and verifies deletion before writing a success
receipt. Failed creation is reconciled only through an exact newly observed
name/type/runtime match. Existing simulators are never adopted or deleted.

```sh
uv run scripts/capture-app-store-screenshots.py prepare
uv run scripts/capture-app-store-screenshots.py build ios
uv run scripts/capture-app-store-screenshots.py capture iphone65 --output /absolute/new/iphone65
```

Other base profiles are `iphone`, `ipad`, `watch`, `visionpro` and `tvos`;
use the matching `watchos`, `visionos` or `tvos` build command first. Detail
profiles append `-detail` to an iPhone, iPad or Vision Pro profile.
`watch-accounts` captures the native account list after scrolling. Each output
folder records its exact source, bundle, runtime, image hashes and verified
owned-device cleanup in `capture.json`. Only complete receipts plus visual
acceptance make candidates; command success alone does not prove the screen.

For iOS, XCTest launches the fixture, checks foreground state and expected
native content, opens the fixture-seeded native account route for detail, and
takes `XCUIScreen.main.screenshot()`. Accessibility hierarchies and the test
result bundle provide diagnostic evidence. Noninteractive container geometry
is checked without requiring a tap target.

Other simulators use the [Q605 staging decision](https://github.com/cbusillo/context-panel/issues/744#issuecomment-6307013529):
`mktemp -d` in the system temporary directory, save a PNG, validate/copy to the
external output, then delete that PNG and empty temporary directory. Only a
system-temp screenshot save refused with Cocoa code 513 permits staging in a
fresh folder inside the owned fixture-app container. Every other refusal
stops; container fallback is never an automatic retry for unrelated errors.
Cleanup preserves the original error if removing the temporary folder fails.
No stdout workaround or persistent internal image folder is used.

For Mac compositor evidence, dispatch CI on the PR branch with
`app_store_mac_capture=true`. Its optional job runs `ci-macos` only on a
GitHub-hosted macOS runner, collects four native XCTest window screenshots and
exports their attachments. The tool checks the actual hosted environment
before project generation; the fixture app also guards direct launch. The
app temporarily chooses a supported display mode that fits its entire window
and hides its own Dock/menu bar during capture. [Core Graphics restores the
mode when the process exits](https://developer.apple.com/documentation/coregraphics/cgdisplaysetdisplaymode(_:_:_:)).
The actual Mac widget capture adds small, medium and large through the native
gallery, closes it, binds each fixture accessibility group to a distinct new
window from the same process, and checks Core-generated account labels in
each widget. The final frame requires visual acceptance of every account row,
ring and layout. A pointer hover to verified empty wallpaper clears the Dock
tooltip.
The final 1280×800-point crop keeps native pixels and every complete widget;
it excludes the observed Dock and never resizes or paints the desktop.
The test runner receives the actual hosted flags through xcodebuild’s
TEST_RUNNER_ environment transport.

The disposable hosted VM starts its existing per-user Notification Center agent
for desktop widgets and records the setup. The VM is discarded after the job;
no Chris-host desktop preference or permission setting is changed. The
[successful native Mac capture run](https://github.com/cbusillo/context-panel/actions/runs/39545237236)
is retained in each app image's provenance. The
[successful desktop widget run](https://github.com/cbusillo/context-panel/actions/runs/39582398246)
is recorded separately in the widget image's provenance.

`rgb SOURCE NEW.png` performs the lossless opaque-alpha removal used for the
selected native images. It refuses existing output files and transparency.

## Comparison evidence

The [earlier 14-image draft](../horizon-draft/README.md) remains available as
host-rendered comparison evidence. The previous four offscreen Mac window
candidates are retained in [their earlier committed capture index](https://github.com/cbusillo/context-panel/tree/4f058f47e09edd24e095695f4f6b1f61b9e82be9/Resources/AppStore/Screenshots/horizon-capture).
They are superseded by the native Mac images above. Neither comparison set
proves OS widget placement. Historical approved uploader mappings remain
unchanged until Chris approves the complete set and the separate upload step
uses `Upload App Store Screenshots`.
