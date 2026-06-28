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

## Current Upload Mapping

This matrix is not release-complete until the Vision Pro slots below are filled
or explicitly deferred.

Staged iPhone upload candidates:

- iPhone app, light mode, synced-data state:
  `iphone/iphone-6-3-app-light-synced.png`.
- iPhone app, dark mode, synced-data state:
  `iphone/iphone-6-3-app-dark-synced.png`.
- iPhone widget, light mode, Home Screen:
  `iphone/iphone-6-3-widget-light-home.png`.
- iPhone widget, dark mode, Home Screen:
  `iphone/iphone-6-3-widget-dark-home.png`.

Missing or deferred before submission:

- Vision Pro app, light mode, synced-data state.
- Vision Pro app, dark mode, synced-data state.
- Vision Pro widget, small, healthy synced-data state.
- Vision Pro widget, medium, healthy synced-data state.
- Vision Pro degraded or stale-first state.

## Remaining Matrix Gaps

- Confirm whether App Store Connect will accept the iPhone 6.3-inch captures for
  the intended iPhone screenshot slots, or capture/export the required 6.9-inch
  or fallback 6.5-inch iPhone set.
- Capture Vision Pro app light mode with synced data.
- Capture Vision Pro app dark mode with synced data.
- Capture Vision Pro small widget with healthy synced data.
- Capture Vision Pro medium widget with healthy synced data.
- Capture a Vision Pro degraded or stale-first state when practical, or record a
  deliberate deferral before submission.
