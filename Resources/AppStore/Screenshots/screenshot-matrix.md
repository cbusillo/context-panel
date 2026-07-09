# App Store Screenshot Matrix

Source plan: [#299](https://github.com/cbusillo/context-panel/issues/299)

Apple screenshot specs checked on 2026-06-27:
[Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)

## Mac Captures

The Mac app screenshot was recaptured from the canonical installed app,
`/Applications/Context Panel.app`, on 2026-07-06 after Chris approval. The
widget screenshot is the existing approved staged composition. Three additional
Mac screenshots were captured from display 2 on 2026-07-06 to fill out the Mac
App Store set. Those three display captures have the Tesla widget address
redacted and were approved by Chris on 2026-07-06.
All files use App Store Connect-accepted 16:10 Mac screenshot sizes.

- `final/context-panel-appstore-1-app.png`
  - Source: canonical installed Mac app window capture
  - Surface: App
  - Appearance: Light
  - State: Overview, synced data
  - Dimensions: 1440 x 900
- `final/context-panel-appstore-2-widget.png`
  - Source: staged Mac widget App Store composition
  - Surface: Widget
  - Appearance: Dark
  - State: Synced data
  - Dimensions: 2880 x 1800
- `final/context-panel-appstore-3-app-dark-current.png`
  - Source: display 2 screenshot crop, address redacted
  - Surface: App with widget context
  - Appearance: Dark
  - State: Overview, synced data
  - Dimensions: 1440 x 900
  - Approval: Chris approved on 2026-07-06
- `final/context-panel-appstore-4-widgets-live-redacted.png`
  - Source: display 2 screenshot crop, address redacted
  - Surface: Desktop widgets with app context
  - Appearance: Dark
  - State: Synced data
  - Dimensions: 1440 x 900
  - Approval: Chris approved on 2026-07-06
- `final/context-panel-appstore-5-glance-detail-redacted.png`
  - Source: display 2 screenshot crop, address redacted
  - Surface: Desktop widgets with app detail context
  - Appearance: Dark
  - State: Synced data
  - Dimensions: 1440 x 900
  - Approval: Chris approved on 2026-07-06

Mac checksums:

```text
0d7fd6292e297aedeecac620e728f6e7730315bd3a023810d46957f02a918bec  final/context-panel-appstore-1-app.png
5e3c9cff997e504deb4f49771f821a896acfe8790de8acc90e217f4efad11c88  final/context-panel-appstore-2-widget.png
14ee260b8583c747dc4499cd13eba85cd0f28df86fdd5c9fbdbb1de97448d93e  final/context-panel-appstore-3-app-dark-current.png
627597d3462b30ad6d3e4d2e049082be703d4bc60cc29b30ae7ea67fcd438d35  final/context-panel-appstore-4-widgets-live-redacted.png
ac864aa1be373493c2e67a32f21366777f8f65da9f1969136e8f4b7712ad3431  final/context-panel-appstore-5-glance-detail-redacted.png
```

## Approved iPhone Captures

These screenshots were copied from Chris's Desktop on 2026-07-06 after visual
approval. They are unedited PNG captures at 1206 x 2622, an accepted iPhone
6.3-inch portrait size. The predictable release path for these current iPhone
upload candidates is `Resources/AppStore/Screenshots/iphone/`.

- `iphone/iphone-6-3-app-light-synced.png`
  - Original: `IMG_0363.PNG` from Chris's Desktop
  - Surface: App
  - Appearance: Light
  - State: Synced data
  - Dimensions: 1206 x 2622
- `iphone/iphone-6-3-app-dark-synced.png`
  - Original: `IMG_0365.PNG` from Chris's Desktop
  - Surface: App
  - Appearance: Dark
  - State: Synced data
  - Dimensions: 1206 x 2622
- `iphone/iphone-6-3-widget-light-home.png`
  - Original: `IMG_0362.PNG` from Chris's Desktop
  - Surface: Widget
  - Appearance: Light
  - State: Home Screen synced data
  - Dimensions: 1206 x 2622
- `iphone/iphone-6-3-widget-dark-home.png`
  - Original: `IMG_0364.PNG` from Chris's Desktop
  - Surface: Widget
  - Appearance: Dark
  - State: Home Screen synced data
  - Dimensions: 1206 x 2622

Checksums:

```text
901d634305b05eadace01635b976a013f4d37841c6d25877ab4e7cd226defd95  iphone/iphone-6-3-app-light-synced.png
85a3b6c422e8ba0d72c3e2ae5a5a6c133351e1391c692d3a37c4440767d0d5aa  iphone/iphone-6-3-app-dark-synced.png
2423cbf9f70b536a0c490dc065e65aeb372432373899165e85d17c7f50ba81d8  iphone/iphone-6-3-widget-light-home.png
42f1c20e996447c25c28adc61eb7ff9729753fad6d8066b7acede287aec43fe5  iphone/iphone-6-3-widget-dark-home.png
```

## Required iPhone 6.5-Inch Captures

App Store Connect rejected the iOS 1.0.40 submission on 2026-07-07 until an
`APP_IPHONE_65` screenshot set was present. These screenshots are derived from
the approved iPhone 6.3-inch captures above with an aspect-preserving resize and
center crop to 1284 x 2778, an accepted iPhone 6.5-inch portrait size. They were
visually checked after generation and should stay in the approved iOS upload
matrix unless Apple changes the screenshot requirements.

- `iphone65/iphone-6-5-app-light-synced.png`
  - Source: `iphone/iphone-6-3-app-light-synced.png`
  - Surface: App
  - Appearance: Light
  - State: Synced data
  - Dimensions: 1284 x 2778
- `iphone65/iphone-6-5-app-dark-synced.png`
  - Source: `iphone/iphone-6-3-app-dark-synced.png`
  - Surface: App
  - Appearance: Dark
  - State: Synced data
  - Dimensions: 1284 x 2778
- `iphone65/iphone-6-5-widget-light-home.png`
  - Source: `iphone/iphone-6-3-widget-light-home.png`
  - Surface: Widget
  - Appearance: Light
  - State: Home Screen synced data
  - Dimensions: 1284 x 2778
- `iphone65/iphone-6-5-widget-dark-home.png`
  - Source: `iphone/iphone-6-3-widget-dark-home.png`
  - Surface: Widget
  - Appearance: Dark
  - State: Home Screen synced data
  - Dimensions: 1284 x 2778

iPhone 6.5-inch checksums:

```text
bb090ceb5a598b16e0501296b970cecde2a4ab1284410206deac583925aa79dc  iphone65/iphone-6-5-app-light-synced.png
31b384c6f53e2c79546a76839df659dabe31eb9d8cb9f5b77e88863f9a1dde9a  iphone65/iphone-6-5-app-dark-synced.png
e5e932615d877e89c1933b8553eea03934917dd32898e9d35afa6a49607fd618  iphone65/iphone-6-5-widget-light-home.png
719939b9e01673782e2d761f502176838c13fc858b5389d9358a7b06875a99e4  iphone65/iphone-6-5-widget-dark-home.png
```

## Approved iPad Captures

These screenshots were captured by Chris from a physical 12.9-inch iPad Pro and
copied from Chris's Desktop on 2026-07-06 after visual review. They are app-only
PNG captures resized from 2384 x 3180 to 2048 x 2732, an accepted 12.9-inch iPad
Pro portrait size. The predictable release path for these current iPad upload
candidates is `Resources/AppStore/Screenshots/ipad/`.

The older ASC-only iPad image, `context-panel-ios-ipad129.png`, is not part of
the approved repo matrix. Replace it with these repo-tracked iPad captures when
preparing the next editable iOS App Store version.

- `ipad/ipad-12-9-app-light-synced.png`
  - Original: `IMG_0018.PNG` from Chris's Desktop
  - Source: physical iPad Pro screenshot
  - Surface: App
  - Appearance: Light
  - State: Synced data
  - Dimensions: 2048 x 2732
- `ipad/ipad-12-9-app-dark-synced.png`
  - Original: `IMG_0019.PNG` from Chris's Desktop
  - Source: physical iPad Pro screenshot
  - Surface: App
  - Appearance: Dark
  - State: Synced data
  - Dimensions: 2048 x 2732

iPad checksums:

```text
47abe15aaf7d88f51dc367a3e81db334cdbcac02f041921f9cd13bf048791332  ipad/ipad-12-9-app-light-synced.png
680e33eed9c18ea5e1008d66e4de71fbf8a37d1d4acaccadbc0e2d0cc28de13e  ipad/ipad-12-9-app-dark-synced.png
```

## Imported Vision Pro Simulator Captures

These screenshots were captured from the booted `Context Panel AVP` Apple Vision
Pro simulator on 2026-06-28 and approved for release use on 2026-07-06. The
simulator was running a fresh Debug build of the `ContextPanelCompanion` scheme
installed from
`.build/visionpro-screenshot-derived/Build/Products/Debug-xrsimulator/Context Panel.app`.

The app-group companion mirror was seeded with sanitized sample data for OpenAI,
Anthropic, and Google. The visible status card records that the latest Mac
snapshot loaded from the local mirror and CloudKit was unavailable. These are
simulator candidates, not physical Apple Vision Pro captures.

The predictable release path for these current Vision Pro app candidates is
`Resources/AppStore/Screenshots/visionpro/`.

- `visionpro/visionpro-app-light-synced-simulator.png`
  - Source: Vision Pro simulator screenshot via `xcrun simctl io screenshot`
  - Simulator: `Context Panel AVP` (`259BB160-DAD9-4300-BA6B-F892F489E0F7`)
  - Surface: App
  - Appearance: Light
  - State: Synced data from seeded local companion mirror
  - Dimensions: 3840 x 2160
- `visionpro/visionpro-app-dark-synced-simulator.png`
  - Source: Vision Pro simulator screenshot via `xcrun simctl io screenshot`
  - Simulator: `Context Panel AVP` (`259BB160-DAD9-4300-BA6B-F892F489E0F7`)
  - Surface: App
  - Appearance: Dark
  - State: Synced data from seeded local companion mirror
  - Dimensions: 3840 x 2160
- `visionpro/visionpro-app-stale-sync-simulator.png`
  - Source: Vision Pro simulator screenshot via `xcrun simctl io screenshot`
  - Simulator: `Context Panel AVP` (`259BB160-DAD9-4300-BA6B-F892F489E0F7`)
  - Surface: App
  - Appearance: Light
  - State: Stale Mac sync / provider refresh needed
  - Dimensions: 3840 x 2160

Vision Pro simulator checksums:

```text
2c70cb155ea8143d6000745d75f91119cd01ef4cebc3c00dd427c54abb527377  visionpro/visionpro-app-light-synced-simulator.png
53308552756027e742f53f7c9a29436037249127b06253f9927f8f8a52b0e017  visionpro/visionpro-app-dark-synced-simulator.png
7b401c8f5115a586e2f49f020eefbf0f22cd13d61e6aa5d0c84b61baa9103173  visionpro/visionpro-app-stale-sync-simulator.png
```

## Vision Pro Widget Render Candidates

These images were generated on 2026-06-28 from the same shared SwiftUI widget
surface used by the app and widget targets: `ContextPanelWidgetContentView`
rendered with `ImageRenderer` and sanitized sample data for OpenAI, Anthropic,
and Google. They are 3840 x 2160 Vision Pro canvas candidates, not screenshots
of WidgetKit placed on a physical Apple Vision Pro or simulator Home View.

Chris approved these generated Vision Pro widget compositions for release use on
2026-07-06 because the physical Apple Vision Pro captures were fuzzy. Replace
them only if App Store Connect or App Review requires literal placed-widget
screenshots.

- `visionpro/visionpro-widget-small-healthy-light-rendered.png`
  - Source: SwiftUI widget renderer candidate
  - Surface: Widget, small family
  - Appearance: Light
  - State: Healthy synced sample data
  - Dimensions: 3840 x 2160
- `visionpro/visionpro-widget-small-healthy-dark-rendered.png`
  - Source: SwiftUI widget renderer candidate
  - Surface: Widget, small family
  - Appearance: Dark
  - State: Healthy synced sample data
  - Dimensions: 3840 x 2160
- `visionpro/visionpro-widget-medium-healthy-light-rendered.png`
  - Source: SwiftUI widget renderer candidate
  - Surface: Widget, medium family
  - Appearance: Light
  - State: Healthy synced sample data
  - Dimensions: 3840 x 2160
- `visionpro/visionpro-widget-medium-healthy-dark-rendered.png`
  - Source: SwiftUI widget renderer candidate
  - Surface: Widget, medium family
  - Appearance: Dark
  - State: Healthy synced sample data
  - Dimensions: 3840 x 2160

Vision Pro widget render checksums:

```text
ebcda76f5abc7568c228a115054a8d343d68d27990c219e9162666b68297984c  visionpro/visionpro-widget-small-healthy-light-rendered.png
b85baab4e91ddeacff118c430d69ff7e398c1d521716fbbee096a6924270399c  visionpro/visionpro-widget-small-healthy-dark-rendered.png
293f599924a6020faf3445cb803a7a62e218a2b2f96e99d7a55d78acb3a4ad12  visionpro/visionpro-widget-medium-healthy-light-rendered.png
8ccac214b91be79494b7bf15d09af650c75942e98abc8b34c30b80061c694f7c  visionpro/visionpro-widget-medium-healthy-dark-rendered.png
```

## Approved Apple Watch Captures

These screenshots were captured by Chris from a physical Apple Watch and copied
from Chris's Desktop on 2026-07-06 after visual approval. They are 410 x 502,
an accepted Apple Watch Ultra / Ultra 2 screenshot size. Use the healthy state
first in App Store ordering, followed by the limited/pressure state.

- `watch/watch-ultra-healthy.png`
  - Original: `incoming-77CC0C0D-6DD3-40E3-B8C9-03694265F2DF.PNG` from
    Chris's Desktop
  - Source: physical Apple Watch screenshot
  - Surface: Watch app
  - Appearance: Dark
  - State: Healthy / available limits
  - Dimensions: 410 x 502
- `watch/watch-ultra-limited.png`
  - Original: `incoming-3ED771EC-4670-43BB-8833-DF6798C8B2CF.PNG` from
    Chris's Desktop
  - Source: physical Apple Watch screenshot
  - Surface: Watch app
  - Appearance: Dark
  - State: Limited / pressure state
  - Dimensions: 410 x 502

Apple Watch checksums:

```text
59d3636ab0b25de7a51796df9cd802d65f7f6be082e4e89f6f48e9bc09c84aab  watch/watch-ultra-healthy.png
5065ad9c1b29ca18a7e47fbccc391ce619ac05e9c02fd57bd7c33819630d1404  watch/watch-ultra-limited.png
```

## Current Upload Mapping

This matrix has Chris-approved local candidates for release upload. Direct local
App Store Connect verification on 2026-07-07 confirmed the approved Mac,
iPhone, iPad, Watch, and Vision Pro files in ASC with matching filenames,
matching dimensions, and `COMPLETE` processing state. This verifies image
upload/processing only; it does not mean all platform versions are release-ready.

Staged Mac upload candidates:

- Mac app, light mode, synced-data overview:
  `final/context-panel-appstore-1-app.png`.
- Mac widget, dark mode, synced-data state:
  `final/context-panel-appstore-2-widget.png`.
- Mac app, dark mode, current synced-data overview, address redacted:
  `final/context-panel-appstore-3-app-dark-current.png`.
- Mac desktop widgets with app context, dark mode, address redacted:
  `final/context-panel-appstore-4-widgets-live-redacted.png`.
- Mac glance-to-detail view, dark mode, address redacted:
  `final/context-panel-appstore-5-glance-detail-redacted.png`.

Staged iPhone upload candidates:

- iPhone app, light mode, synced-data state:
  `iphone/iphone-6-3-app-light-synced.png`.
- iPhone app, dark mode, synced-data state:
  `iphone/iphone-6-3-app-dark-synced.png`.
- iPhone widget, light mode, Home Screen:
  `iphone/iphone-6-3-widget-light-home.png`.
- iPhone widget, dark mode, Home Screen:
  `iphone/iphone-6-3-widget-dark-home.png`.

For iOS App Store versions, prefer the combined uploader set `ios` instead of
uploading individual `iphone`, `ipad`, and `watch` sets. The combined set
replaces every approved iOS-family display type, including the ASC-required
`APP_IPHONE_65` set, and prunes unapproved screenshot display types.

Staged iPad upload candidates:

- iPad app, light mode, synced-data state:
  `ipad/ipad-12-9-app-light-synced.png`.
- iPad app, dark mode, synced-data state:
  `ipad/ipad-12-9-app-dark-synced.png`.

Staged Vision Pro simulator app candidates:

- Vision Pro app, light mode, synced-data state:
  `visionpro/visionpro-app-light-synced-simulator.png`.
- Vision Pro app, dark mode, synced-data state:
  `visionpro/visionpro-app-dark-synced-simulator.png`.
- Vision Pro app, stale Mac sync / provider refresh needed state:
  `visionpro/visionpro-app-stale-sync-simulator.png`.

Staged Vision Pro widget render candidates:

- Vision Pro widget, small, light mode, healthy synced-data state:
  `visionpro/visionpro-widget-small-healthy-light-rendered.png`.
- Vision Pro widget, small, dark mode, healthy synced-data state:
  `visionpro/visionpro-widget-small-healthy-dark-rendered.png`.
- Vision Pro widget, medium, light mode, healthy synced-data state:
  `visionpro/visionpro-widget-medium-healthy-light-rendered.png`.
- Vision Pro widget, medium, dark mode, healthy synced-data state:
  `visionpro/visionpro-widget-medium-healthy-dark-rendered.png`.

Staged Apple Watch upload candidates:

- Apple Watch app, healthy / available limits state:
  `watch/watch-ultra-healthy.png`.
- Apple Watch app, limited / pressure state:
  `watch/watch-ultra-limited.png`.

## Remaining Matrix Gaps

Verified ASC image state on 2026-07-08 after iOS App Review approval:

- `MAC_OS` `1.0.39` is `PREPARE_FOR_SUBMISSION`; `APP_DESKTOP` has the 5
  approved Mac screenshots, all `COMPLETE`.
- `IOS` `1.0.40` is `READY_FOR_SALE`; `APP_IPHONE_61` has the 4 approved iPhone
  screenshots, all `COMPLETE`.
- `IOS` `1.0.40` is `READY_FOR_SALE`; `APP_IPHONE_65` has the 4 approved
  derived iPhone 6.5-inch screenshots, all `COMPLETE`.
- `IOS` `1.0.40` is `READY_FOR_SALE`; `APP_IPAD_PRO_3GEN_129` has the 2 approved
  repo-tracked iPad screenshots, all `COMPLETE`.
- `IOS` `1.0.40` is `READY_FOR_SALE`; `APP_WATCH_ULTRA` has the 2 approved Apple
  Watch screenshots, all `COMPLETE`.
- `VISION_OS` `1.0.38` is `REJECTED`; `APP_APPLE_VISION_PRO` has the 7
  approved Vision Pro screenshots, all `COMPLETE`.

Release blockers / follow-up before cutting another multi-platform release:

- iOS `1.0.40` is accepted and live. Keep future iOS screenshot changes on a
  fresh editable version; do not mutate the accepted release as release prep.
- Do not resubmit rejected marketing versions as the next release candidate.
  Prepare the next marketing version first, then copy/upload the approved
  screenshot matrix there.
- Fresh `VISION_OS` `1.0.39` preparation was attempted after iOS acceptance, but
  App Store Connect rejected `POST /appStoreVersions` while rejected `1.0.38`
  remains the active visionOS state. Do not delete rejected `1.0.38` without an
  explicit recovery decision; use it as audit history until Apple/ASC allows the
  next fresh visionOS version.
- Validate visionOS CloudKit receive/mirror/widget behavior on Apple Vision Pro
  before submitting the fresh visionOS version for review.
- The approved iOS-family set now includes `APP_IPHONE_61`,
  `APP_IPHONE_65`, `APP_IPAD_PRO_3GEN_129`, and `APP_WATCH_ULTRA`.
- Replace Vision Pro generated/simulator assets only if App Store Connect or App
  Review rejects the approved sources.
