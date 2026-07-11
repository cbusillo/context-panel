import CoreGraphics

public enum CompanionLayoutMode: Equatable, Sendable {
    case singleColumn
    case twoColumn
}

public enum CompanionLayoutPolicy {
    public static let twoColumnMinimumWidth: CGFloat = 810
    public static let phonePagePadding: CGFloat = 16
    public static let singleColumnSpacing: CGFloat = 18
    public static let singleColumnMaximumWidth: CGFloat = 720
    public static let twoColumnMaximumWidth: CGFloat = 1_080
    public static let instrumentMinimumWidth: CGFloat = 400
    public static let instrumentMaximumWidth: CGFloat = 720
    public static let settingsColumnWidth: CGFloat = 340
    public static let columnSpacing: CGFloat = 20
    public static let wideWidgetHeight: CGFloat = 360
    public static let regularPagePadding: CGFloat = 24

    public static func mode(
        availableWidth: CGFloat,
        isPhone: Bool,
        usesAccessibilityTextSizes: Bool
    ) -> CompanionLayoutMode {
        guard availableWidth.isFinite,
              availableWidth >= twoColumnMinimumWidth,
              !isPhone,
              !usesAccessibilityTextSizes else {
            return .singleColumn
        }
        return .twoColumn
    }

    public static func maximumContentWidth(
        layoutMode: CompanionLayoutMode,
        isPhone: Bool
    ) -> CGFloat? {
        guard !isPhone else { return nil }
        switch layoutMode {
        case .singleColumn:
            return singleColumnMaximumWidth
        case .twoColumn:
            return twoColumnMaximumWidth
        }
    }

    public static func pagePadding(isPhone: Bool) -> CGFloat {
        isPhone ? phonePagePadding : regularPagePadding
    }
}
