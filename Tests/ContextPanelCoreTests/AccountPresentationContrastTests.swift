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
    }
}
