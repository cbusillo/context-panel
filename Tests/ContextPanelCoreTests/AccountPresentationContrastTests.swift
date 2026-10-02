import Foundation
import Testing
@testable import ContextPanelCore

private func luminance(_ token: AccountColorToken, dark: Bool) -> Double {
    let rgb = token.rgb(dark: dark)
    func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
    return 0.2126 * linear(rgb.red) + 0.7152 * linear(rgb.green) + 0.0722 * linear(rgb.blue)
}
@Test func sharedAccountTextTokensAndActionLabelsMeetAAInBothThemes() {
    let text: [AccountColorToken] = [.primary, .secondary, .tertiary, .available, .low, .critical, .saved, .banked, .next, .openAI, .anthropic, .google]
    for dark in [false, true] {
        for background in [AccountColorToken.surface, .card] {
            for foreground in text {
                let first = luminance(foreground, dark: dark), second = luminance(background, dark: dark)
                #expect((max(first, second) + 0.05) / (min(first, second) + 0.05) >= 4.5)
            }
        }
        for fill in [AccountColorToken.actionFill, .destructiveFill] {
            let first = luminance(.actionText, dark: dark), second = luminance(fill, dark: dark)
            #expect((max(first, second) + 0.05) / (min(first, second) + 0.05) >= 4.5)
        }
        // Each provider's tinted "use next" card: its words, and every provider name, which also appears on it in callouts.
        for surface in Provider.allCases.map(\.surfaceToken) {
            for foreground in [AccountColorToken.primary, .secondary, .openAI, .anthropic, .google] {
                let first = luminance(foreground, dark: dark), second = luminance(surface, dark: dark)
                #expect((max(first, second) + 0.05) / (min(first, second) + 0.05) >= 4.5, "\(foreground) on \(surface), dark \(dark)")
            }
        }
    }
}

@Test func providerCardSurfacesAreDistinctTintsOfTheirHue() {
    for dark in [false, true] {
        let surfaces = Provider.allCases.map { $0.surfaceToken.rgb(dark: dark) }
        for (index, first) in surfaces.enumerated() {
            for second in surfaces.dropFirst(index + 1) {
                let distance = abs(first.red - second.red) + abs(first.green - second.green) + abs(first.blue - second.blue)
                #expect(distance > 0.08, "provider cards must tell apart at a glance")
            }
        }
    }
}
