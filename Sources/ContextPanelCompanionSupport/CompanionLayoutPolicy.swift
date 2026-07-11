import CoreGraphics

public enum CompanionLayoutMode: Equatable, Sendable {
    case singleColumn
    case twoColumn
}

public enum CompanionLayoutPlatform: Equatable, Sendable {
    case phone
    case pad
    case visionOS
}

public enum CompanionLayoutPolicy {
    public static let twoColumnMinimumContentWidth: CGFloat = 824
    public static let phonePagePadding: CGFloat = 16
    public static let singleColumnSpacing: CGFloat = 18
    public static let singleColumnMaximumWidth: CGFloat = 760
    public static let twoColumnMaximumWidth: CGFloat = 1_240
    public static let instrumentMinimumWidth: CGFloat = 440
    public static let instrumentMaximumWidth: CGFloat = 820
    public static let settingsColumnWidth: CGFloat = 360
    public static let columnSpacing: CGFloat = 24
    public static let wideWidgetHeight: CGFloat = 360
    public static let regularPagePadding: CGFloat = 24
    public static let visionTwoColumnMinimumWidth: CGFloat = 810
    public static let visionSingleColumnMaximumWidth: CGFloat = 720
    public static let visionTwoColumnMaximumWidth: CGFloat = 1_080
    public static let visionInstrumentMinimumWidth: CGFloat = 400
    public static let visionInstrumentMaximumWidth: CGFloat = 720
    public static let visionSettingsColumnWidth: CGFloat = 340
    public static let visionColumnSpacing: CGFloat = 20

    public static func mode(
        availableWidth: CGFloat,
        platform: CompanionLayoutPlatform,
        usesAccessibilityTextSizes: Bool
    ) -> CompanionLayoutMode {
        guard availableWidth.isFinite,
              !usesAccessibilityTextSizes else {
            return .singleColumn
        }
        switch platform {
        case .phone:
            return .singleColumn
        case .pad:
            let contentWidth = availableWidth - (regularPagePadding * 2)
            return contentWidth >= twoColumnMinimumContentWidth ? .twoColumn : .singleColumn
        case .visionOS:
            return availableWidth >= visionTwoColumnMinimumWidth ? .twoColumn : .singleColumn
        }
    }

    public static func maximumContentWidth(
        layoutMode: CompanionLayoutMode,
        platform: CompanionLayoutPlatform
    ) -> CGFloat? {
        switch platform {
        case .phone:
            return nil
        case .pad:
            return layoutMode == .singleColumn ? singleColumnMaximumWidth : twoColumnMaximumWidth
        case .visionOS:
            return layoutMode == .singleColumn
                ? visionSingleColumnMaximumWidth
                : visionTwoColumnMaximumWidth
        }
    }

    public static func pagePadding(platform: CompanionLayoutPlatform) -> CGFloat {
        platform == .phone ? phonePagePadding : regularPagePadding
    }

    public static func instrumentMinimumWidth(platform: CompanionLayoutPlatform) -> CGFloat {
        platform == .visionOS ? visionInstrumentMinimumWidth : instrumentMinimumWidth
    }

    public static func instrumentMaximumWidth(platform: CompanionLayoutPlatform) -> CGFloat {
        platform == .visionOS ? visionInstrumentMaximumWidth : instrumentMaximumWidth
    }

    public static func settingsColumnWidth(platform: CompanionLayoutPlatform) -> CGFloat {
        platform == .visionOS ? visionSettingsColumnWidth : settingsColumnWidth
    }

    public static func columnSpacing(platform: CompanionLayoutPlatform) -> CGFloat {
        platform == .visionOS ? visionColumnSpacing : columnSpacing
    }
}
