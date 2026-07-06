# App Store Screenshot Matrix

Source plan: [#299](https://github.com/cbusillo/context-panel/issues/299)

Apple screenshot specs checked on 2026-06-27:
[Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)

## Approved Mac Captures

The Mac app screenshot was recaptured from the canonical installed app,
`/Applications/Context Panel.app`, on 2026-07-06 after Chris approval. The
widget screenshot is the existing approved staged composition. Both files use
App Store Connect-accepted 16:10 Mac screenshot sizes.

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

Mac checksums:

```text
0d7fd6292e297aedeecac620e728f6e7730315bd3a023810d46957f02a918bec  final/context-panel-appstore-1-app.png
5e3c9cff997e504deb4f49771f821a896acfe8790de8acc90e217f4efad11c88  final/context-panel-appstore-2-widget.png
```

## Approved iPhone Captures

These screenshots were copied from Chris's Desktop on 2026-07-06 after visual
approval. They are unedited PNG captures at 1206 x 2622, an accepted iPhone
6.3-inch portrait size. The predictable release path for these current iPhone
upload candidates is `Resources/AppStore/Screenshots/iphone/`.

- `iphone/iphone-6-3-app-light-synced.png`
  - Original: `/Users/cbusillo/Desktop/IMG_0363.PNG`
  - Surface: App
  - Appearance: Light
  - State: Synced data
  - Dimensions: 1206 x 2622
- `iphone/iphone-6-3-app-dark-synced.png`
  - Original: `/Users/cbusillo/Desktop/IMG_0365.PNG`
  - Surface: App
  - Appearance: Dark
  - State: Synced data
  - Dimensions: 1206 x 2622
- `iphone/iphone-6-3-widget-light-home.png`
  - Original: `/Users/cbusillo/Desktop/IMG_0362.PNG`
  - Surface: Widget
  - Appearance: Light
  - State: Home Screen synced data
  - Dimensions: 1206 x 2622
- `iphone/iphone-6-3-widget-dark-home.png`
  - Original: `/Users/cbusillo/Desktop/IMG_0364.PNG`
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
  - Original: `/Users/cbusillo/Desktop/incoming-77CC0C0D-6DD3-40E3-B8C9-03694265F2DF.PNG`
  - Source: physical Apple Watch screenshot
  - Surface: Watch app
  - Appearance: Dark
  - State: Healthy / available limits
  - Dimensions: 410 x 502
- `watch/watch-ultra-limited.png`
  - Original: `/Users/cbusillo/Desktop/incoming-3ED771EC-4670-43BB-8833-DF6798C8B2CF.PNG`
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

This matrix has Chris-approved local candidates for the planned release upload.
Final completion still requires App Store Connect upload and processing-state
verification.

Staged Mac upload candidates:

- Mac app, light mode, synced-data overview:
  `final/context-panel-appstore-1-app.png`.
- Mac widget, dark mode, synced-data state:
  `final/context-panel-appstore-2-widget.png`.

Staged iPhone upload candidates:

- iPhone app, light mode, synced-data state:
  `iphone/iphone-6-3-app-light-synced.png`.
- iPhone app, dark mode, synced-data state:
  `iphone/iphone-6-3-app-dark-synced.png`.
- iPhone widget, light mode, Home Screen:
  `iphone/iphone-6-3-widget-light-home.png`.
- iPhone widget, dark mode, Home Screen:
  `iphone/iphone-6-3-widget-dark-home.png`.

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

- Upload the approved screenshot set to App Store Connect.
- Verify App Store Connect screenshot ids, dimensions, and `COMPLETE`
  processing state after upload.
- Replace Vision Pro generated/simulator assets only if App Store Connect or App
  Review rejects the approved sources.
