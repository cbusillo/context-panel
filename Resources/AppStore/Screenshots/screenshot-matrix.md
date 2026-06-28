# App Store Screenshot Matrix

Source plan: [#299](https://github.com/cbusillo/context-panel/issues/299)

Apple screenshot specs checked on 2026-06-27:
[Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)

## Imported iPhone Captures

These screenshots were copied from Chris's Desktop on 2026-06-27. They are
unedited PNG captures at 1206 x 2622, an accepted iPhone 6.3-inch portrait size.
The predictable release path for these current iPhone upload candidates is
`Resources/AppStore/Screenshots/iphone/`.

- `iphone/iphone-6-3-app-light-synced.png`
  - Original: `/Users/cbusillo/Desktop/IMG_0358.PNG`
  - Surface: App
  - Appearance: Light
  - State: Synced data
- `iphone/iphone-6-3-app-dark-synced.png`
  - Original: `/Users/cbusillo/Desktop/IMG_0359.PNG`
  - Surface: App
  - Appearance: Dark
  - State: Synced data
- `iphone/iphone-6-3-widget-light-home.png`
  - Original: `/Users/cbusillo/Desktop/IMG_0360.PNG`
  - Surface: Widget
  - Appearance: Light
  - State: Home Screen synced data
- `iphone/iphone-6-3-widget-dark-home.png`
  - Original: `/Users/cbusillo/Desktop/IMG_0355.PNG`
  - Surface: Widget
  - Appearance: Dark
  - State: Home Screen synced data

Checksums:

```text
384615b495fe1d81221d5d30cfe657f30fcaf9ef1f54004ddf064010f67c93a0  iphone/iphone-6-3-app-light-synced.png
11ed65f1d13bad89f5c2ea997b217e35c5f685e0d9fdcb3c104fc50c7cec8194  iphone/iphone-6-3-app-dark-synced.png
bcacbcb9ae54d155efd75d4db986159cd92c48613b57076a217053ba614ef28e  iphone/iphone-6-3-widget-light-home.png
4bb0176d2fa8b420285eff5b34631b1a8e388f9bc7675c4f39648691be7715b6  iphone/iphone-6-3-widget-dark-home.png
```

## Imported Vision Pro Simulator Captures

These screenshots were captured from the booted `Context Panel AVP` Apple Vision
Pro simulator on 2026-06-28. The simulator was running a fresh Debug build of the
`ContextPanelCompanion` scheme installed from
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

Use these if App Store Connect accepts rendered/composited widget surfaces for
the Vision Pro screenshot set and the composition is approved as upload-ready.
Replace them with physical-device or simulator WidgetKit placement captures if
review policy or product direction requires literal placed-widget screenshots.

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

## Current Upload Mapping

This matrix has local candidates for each planned slot. It still needs App Store
Connect source acceptance decisions before upload because the Vision Pro app
captures are simulator screenshots and the Vision Pro widget captures are
renderer candidates rather than placed WidgetKit screenshots.

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

## Remaining Matrix Gaps

- Confirm whether App Store Connect will accept the iPhone 6.3-inch captures for
  the intended iPhone screenshot slots, or capture/export the required 6.9-inch
  or fallback 6.5-inch iPhone set.
- Decide whether the staged Vision Pro simulator app captures are acceptable for
  App Store Connect, or replace them with physical Apple Vision Pro captures.
- Decide whether the staged Vision Pro widget render candidates are acceptable
  as upload-ready App Store Connect compositions, or replace them with
  physical-device or simulator placed-widget captures.
