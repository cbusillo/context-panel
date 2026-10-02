import SwiftUI

/// At most two readable quota cards per row; the available pane width decides, not changing text.
struct AccountWindowCardsLayout: Layout {
    private let spacing: CGFloat = 12
    private let minimumCardWidth: CGFloat = 340

    func frames(width: CGFloat, heights: [CGFloat]) -> [CGRect] {
        let columns = width >= 2 * minimumCardWidth + spacing ? 2 : 1
        let cardWidth = max(0, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        var result: [CGRect] = []
        var top: CGFloat = 0
        for start in stride(from: 0, to: heights.count, by: columns) {
            let end = min(start + columns, heights.count)
            let height = heights[start..<end].max() ?? 0
            for index in start..<end {
                result.append(CGRect(x: CGFloat(index - start) * (cardWidth + spacing), y: top,
                                     width: end - start == 1 ? width : cardWidth, height: height))
            }
            top += height + spacing
        }
        return result
    }

    private func measuredFrames(proposal: ProposedViewSize, subviews: Subviews) -> [CGRect] {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 2 * minimumCardWidth + spacing
        let columns = width >= 2 * minimumCardWidth + spacing ? 2 : 1
        let cardWidth = max(0, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        let heights = subviews.enumerated().map { index, view in
            let isLoneLast = columns == 2 && index == subviews.count - 1 && subviews.count % 2 == 1
            return view.sizeThatFits(ProposedViewSize(width: isLoneLast ? width : cardWidth, height: nil)).height
        }
        return frames(width: width, heights: heights)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = measuredFrames(proposal: proposal, subviews: subviews)
        return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, measuredFrames(proposal: ProposedViewSize(width: bounds.width, height: nil), subviews: subviews)) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                       proposal: ProposedViewSize(frame.size))
        }
    }
}
