import CoreGraphics
import Testing

@testable import ContextPanelCompanionSupport

@Test func companionLayoutPolicyUsesTwoColumnsAtRegularWidth() {
    let minimumViewportWidth = CompanionLayoutPolicy.twoColumnMinimumContentWidth
        + (CompanionLayoutPolicy.regularPagePadding * 2)
    #expect(
        CompanionLayoutPolicy.mode(
            availableWidth: minimumViewportWidth,
            platform: .pad,
            usesAccessibilityTextSizes: false
        ) == .twoColumn
    )
    #expect(
        CompanionLayoutPolicy.mode(
            availableWidth: 1_400,
            platform: .pad,
            usesAccessibilityTextSizes: false
        ) == .twoColumn
    )
}

@Test func companionLayoutPolicyKeepsNarrowAndPreferredLayoutsSingleColumn() {
    let minimumViewportWidth = CompanionLayoutPolicy.twoColumnMinimumContentWidth
        + (CompanionLayoutPolicy.regularPagePadding * 2)
    #expect(
        CompanionLayoutPolicy.mode(
            availableWidth: minimumViewportWidth - 1,
            platform: .pad,
            usesAccessibilityTextSizes: false
        ) == .singleColumn
    )
    #expect(
        CompanionLayoutPolicy.mode(
            availableWidth: 1_400,
            platform: .pad,
            usesAccessibilityTextSizes: true
        ) == .singleColumn
    )
}

@Test func companionLayoutPolicyKeepsPhonesFullWidthAndSingleColumn() {
    let layoutMode = CompanionLayoutPolicy.mode(
        availableWidth: 1_400,
        platform: .phone,
        usesAccessibilityTextSizes: false
    )

    #expect(layoutMode == .singleColumn)
    #expect(CompanionLayoutPolicy.maximumContentWidth(layoutMode: layoutMode, platform: .phone) == nil)
    #expect(CompanionLayoutPolicy.pagePadding(platform: .phone) == 16)
}

@Test func companionLayoutPolicyBoundsNonPhoneSingleAndTwoColumnLayouts() {
    #expect(
        CompanionLayoutPolicy.maximumContentWidth(layoutMode: .singleColumn, platform: .pad)
            == CompanionLayoutPolicy.singleColumnMaximumWidth
    )
    #expect(
        CompanionLayoutPolicy.maximumContentWidth(layoutMode: .twoColumn, platform: .pad)
            == CompanionLayoutPolicy.twoColumnMaximumWidth
    )
    #expect(CompanionLayoutPolicy.pagePadding(platform: .pad) == 24)
}

@Test func companionLayoutPolicyRejectsInvalidWidths() {
    #expect(
        CompanionLayoutPolicy.mode(
            availableWidth: -.infinity,
            platform: .pad,
            usesAccessibilityTextSizes: false
        ) == .singleColumn
    )
    #expect(
        CompanionLayoutPolicy.mode(
            availableWidth: .nan,
            platform: .pad,
            usesAccessibilityTextSizes: false
        ) == .singleColumn
    )
    #expect(
        CompanionLayoutPolicy.mode(
            availableWidth: .infinity,
            platform: .pad,
            usesAccessibilityTextSizes: false
        ) == .singleColumn
    )
}

@Test func companionLayoutPolicyMinimumColumnsFitItsBreakpoint() {
    let requiredContentWidth = CompanionLayoutPolicy.instrumentMinimumWidth
        + CompanionLayoutPolicy.columnSpacing
        + CompanionLayoutPolicy.settingsColumnWidth

    #expect(requiredContentWidth <= CompanionLayoutPolicy.twoColumnMinimumContentWidth)
}

@Test func companionLayoutPolicySubtractsPagePaddingBeforeUsingTwoColumns() {
    #expect(
        CompanionLayoutPolicy.mode(
            availableWidth: CompanionLayoutPolicy.twoColumnMinimumContentWidth,
            platform: .pad,
            usesAccessibilityTextSizes: false
        ) == .singleColumn
    )
}

@Test func companionLayoutPolicyPreservesVisionOSGeometry() {
    #expect(
        CompanionLayoutPolicy.mode(
            availableWidth: CompanionLayoutPolicy.visionTwoColumnMinimumWidth,
            platform: .visionOS,
            usesAccessibilityTextSizes: false
        ) == .twoColumn
    )
    #expect(
        CompanionLayoutPolicy.mode(
            availableWidth: CompanionLayoutPolicy.visionTwoColumnMinimumWidth - 1,
            platform: .visionOS,
            usesAccessibilityTextSizes: false
        ) == .singleColumn
    )
    #expect(
        CompanionLayoutPolicy.maximumContentWidth(layoutMode: .twoColumn, platform: .visionOS)
            == CompanionLayoutPolicy.visionTwoColumnMaximumWidth
    )
    #expect(
        CompanionLayoutPolicy.instrumentMaximumWidth(platform: .visionOS)
            == CompanionLayoutPolicy.visionInstrumentMaximumWidth
    )
    #expect(
        CompanionLayoutPolicy.settingsColumnWidth(platform: .visionOS)
            == CompanionLayoutPolicy.visionSettingsColumnWidth
    )
}

/// iPhone 393, iPad mini portrait 744, iPad portrait 834: too narrow for the Mac table's columns.
@Test(arguments: [393, 744, 834] as [CGFloat])
func companionLayoutPolicyStacksAccountsBelowTheMacPaneWidth(width: CGFloat) {
    #expect(!CompanionLayoutPolicy.usesAccountTable(width: width))
}

/// iPad landscape 1194 has room for the table.
@Test func companionLayoutPolicyUsesTheAccountTableInIPadLandscape() {
    #expect(CompanionLayoutPolicy.usesAccountTable(width: 1_194))
}

@Test func companionLayoutPolicySwitchesToTheAccountTableAtTheMacPaneWidth() {
    let threshold = CompanionLayoutPolicy.accountTableMinimumWidth
    #expect(!CompanionLayoutPolicy.usesAccountTable(width: threshold - 1))
    #expect(CompanionLayoutPolicy.usesAccountTable(width: threshold))
}

@Test func companionLayoutPolicyStacksAccountsForInvalidWidths() {
    #expect(!CompanionLayoutPolicy.usesAccountTable(width: .nan))
    #expect(!CompanionLayoutPolicy.usesAccountTable(width: .infinity))
}
