import SwiftUI

/// The frame a host gives a placed surface: its size in points and the corner
/// radius the system clips it with. Shared-view reference images are drawn in this
/// frame rather than on the gallery screen, so a reference shows what a person sees
/// (docs/validation-authority.md#reference-images).
///
/// Sizes come from Apple's Human Interface Guidelines for the simulator device each
/// capture pins in Config/ContextPanelSharedViewSimulators.json. Apple publishes no
/// widget corner radius, so widgets use the commonly measured iPhone value. The
/// Watch and TV apps frame their complication and Top Shelf cells in their own
/// validation gallery sources.
public struct SharedViewFrame: Equatable, Sendable {
    public let width: CGFloat
    public let height: CGFloat
    public let cornerRadius: CGFloat

    public init(width: CGFloat, height: CGFloat, cornerRadius: CGFloat) {
        self.width = width
        self.height = height
        self.cornerRadius = cornerRadius
    }

    public var size: CGSize { CGSize(width: width, height: height) }

    public static let widgetCornerRadius: CGFloat = 22

    /// Pixels per point for every reference image drawn in process.
    public static let referenceScale: CGFloat = 2
}

public extension View {
    /// Lays the view out in the host frame on its container background and clips it
    /// to the host's corner radius. Pixels outside the corners stay transparent.
    func sharedViewFrame<Background: View>(
        _ frame: SharedViewFrame,
        @ViewBuilder background: () -> Background
    ) -> some View {
        self
            .frame(width: frame.width, height: frame.height)
            .background(background())
            .clipShape(RoundedRectangle(cornerRadius: frame.cornerRadius, style: .continuous))
    }
}
