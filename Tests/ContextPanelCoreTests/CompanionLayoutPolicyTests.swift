import Testing

@testable import ContextPanelCompanionSupport

@Test func companionLayoutPolicyUsesTwoColumnsAtRegularWidth() {
    #expect(
        CompanionLayoutPolicy.mode(
            availableWidth: CompanionLayoutPolicy.twoColumnMinimumWidth,
            isPhone: false,
            usesAccessibilityTextSizes: false
        ) == .twoColumn
    )
    #expect(
        CompanionLayoutPolicy.mode(
            availableWidth: 1_400,
            isPhone: false,
            usesAccessibilityTextSizes: false
        ) == .twoColumn
    )
}

@Test func companionLayoutPolicyKeepsNarrowAndPreferredLayoutsSingleColumn() {
    #expect(
        CompanionLayoutPolicy.mode(
            availableWidth: CompanionLayoutPolicy.twoColumnMinimumWidth - 1,
            isPhone: false,
            usesAccessibilityTextSizes: false
        ) == .singleColumn
    )
    #expect(
        CompanionLayoutPolicy.mode(
            availableWidth: 1_400,
            isPhone: false,
            usesAccessibilityTextSizes: true
        ) == .singleColumn
    )
}

@Test func companionLayoutPolicyKeepsPhonesFullWidthAndSingleColumn() {
    let layoutMode = CompanionLayoutPolicy.mode(
        availableWidth: 1_400,
        isPhone: true,
        usesAccessibilityTextSizes: false
    )

    #expect(layoutMode == .singleColumn)
    #expect(CompanionLayoutPolicy.maximumContentWidth(layoutMode: layoutMode, isPhone: true) == nil)
    #expect(CompanionLayoutPolicy.pagePadding(isPhone: true) == 16)
}

@Test func companionLayoutPolicyBoundsNonPhoneSingleAndTwoColumnLayouts() {
    #expect(
        CompanionLayoutPolicy.maximumContentWidth(layoutMode: .singleColumn, isPhone: false)
            == CompanionLayoutPolicy.singleColumnMaximumWidth
    )
    #expect(
        CompanionLayoutPolicy.maximumContentWidth(layoutMode: .twoColumn, isPhone: false)
            == CompanionLayoutPolicy.twoColumnMaximumWidth
    )
    #expect(CompanionLayoutPolicy.pagePadding(isPhone: false) == 24)
}

@Test func companionLayoutPolicyRejectsInvalidWidths() {
    #expect(
        CompanionLayoutPolicy.mode(
            availableWidth: -.infinity,
            isPhone: false,
            usesAccessibilityTextSizes: false
        ) == .singleColumn
    )
    #expect(
        CompanionLayoutPolicy.mode(
            availableWidth: .nan,
            isPhone: false,
            usesAccessibilityTextSizes: false
        ) == .singleColumn
    )
    #expect(
        CompanionLayoutPolicy.mode(
            availableWidth: .infinity,
            isPhone: false,
            usesAccessibilityTextSizes: false
        ) == .singleColumn
    )
}

@Test func companionLayoutPolicyMinimumColumnsFitItsBreakpoint() {
    let requiredWidth = CompanionLayoutPolicy.regularPagePadding * 2
        + CompanionLayoutPolicy.instrumentMinimumWidth
        + CompanionLayoutPolicy.columnSpacing
        + CompanionLayoutPolicy.settingsColumnWidth

    #expect(requiredWidth <= CompanionLayoutPolicy.twoColumnMinimumWidth)
}
