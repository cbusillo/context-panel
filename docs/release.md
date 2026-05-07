# macOS Release Path

Last verified: 2026-05-06.

Context Panel can currently produce a launchable macOS app bundle from the
SwiftPM preview app. This is an interim friend-installable path while the formal
Xcode app and WidgetKit extension packaging is still being built.

## Build A Signed App

```sh
scripts/package-macos-app.sh --output dist --identity auto
```

The script builds `ContextPanelPreview` in release mode, wraps it as
`dist/Context Panel.app`, writes app metadata, signs the bundle, verifies the
signature, and runs a local Gatekeeper assessment.

`--identity auto` asks Keychain for available code-signing identities and
prefers `Developer ID Application`, then `Apple Development`, then ad-hoc
signing. The script does not read private keys or credentials; signing is
performed by macOS Keychain through `codesign`.

Useful variants:

```sh
scripts/package-macos-app.sh --debug
scripts/package-macos-app.sh --identity -
scripts/package-macos-app.sh --product ClaudeWebUsageProbe --display-name "Claude Usage Probe" --bundle-id com.shinycomputers.contextpanel.claudeprobe
```

## Current Constraints

- The package is signed but not notarized by this script.
- The app bundle contains the SwiftPM preview app, not the final Xcode app
  target.
- WidgetKit extension packaging still needs the formal Xcode app/extension
  target before friends can add the widget to Notification Center.
- The app reads and writes local snapshots under Context Panel's Application
  Support directory.

## Validation

On 2026-05-06, `scripts/package-macos-app.sh --output dist --identity auto`
produced `dist/Context Panel.app`, signed with Developer ID Application:
Shiny Computers Leasing LLC, and `spctl --assess --type execute` accepted the
bundle as Developer ID signed.
