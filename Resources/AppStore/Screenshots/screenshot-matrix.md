# App Store Screenshot Matrix

The App Store listing uses the 27 Horizon images in
[horizon-capture/](horizon-capture/README.md). Chris approved these exact image
bytes on October 21, 2026
([Q612](https://github.com/cbusillo/context-panel/issues/744#issuecomment-6317232568)).
[The capture manifest](horizon-capture/manifest.json) is the single source for
each image's size, SHA-256 checksum, source commit and capture provenance.

## Upload mapping

`APPROVED_SETS` in [`scripts/upload-app-store-screenshots.py`](../../../scripts/upload-app-store-screenshots.py)
maps every approved image to its App Store Connect display type and sets the
upload order. Upload with the `Upload App Store Screenshots` workflow, one set
per platform: `macos`, `ios` (iPhone 6.3-inch and 6.5-inch, iPad and Watch),
`visionpro` and `tvos`. A full-platform upload removes screenshots of display
types the set does not include. Run it with `dry_run` first.

Screenshots attach to an editable App Store version. Create the version with
`Submit App Store Review` and `prepare_only` before uploading
([release procedure](../../../docs/release.md#app-store-review-submission)).

## Other sets

[horizon-draft/](horizon-draft/README.md) is the earlier 14-image draft. It is
not approved and not uploaded. The pre-Horizon July 2026 screenshots were
removed from the repository once the Horizon set replaced them; they remain in
Git history.

Apple's [screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
define the accepted sizes.
