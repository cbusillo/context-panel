import ContextPanelCore
import ContextPanelTVSupport
import Foundation
@preconcurrency import TVServices
import UIKit

final class ContextPanelTVTopShelfProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        let now = Date()
        let document = TVTopShelfSharedLocations.live()
            .flatMap { TVTopShelfDocumentStore(documentURL: $0.documentURL).load() }
            ?? Self.missingDocument(now: now)
        return try? TVTopShelfRenderer().content(document: document, now: now)
    }

    private static func missingDocument(now: Date) -> TVTopShelfDocument {
        TVTopShelfDocument(
            snapshot: WidgetSnapshot(
                state: .setupNeeded,
                generatedAt: now,
                limits: [],
                status: .unknown,
                message: "Open Context Panel on your Mac to publish provider runway."
            ),
            mode: .countsOnly,
            now: now
        )
    }
}

private struct TVTopShelfRenderer {
    private static let maximumCardCount = Provider.allCases.count
    private static let renderVersion = 3
    private let fileManager = FileManager.default

    func content(document: TVTopShelfDocument, now: Date) throws -> TVTopShelfInsetContent {
        let imageDirectory = try prepareImageDirectory()
        let existingImageURLs = Set(imageFiles(in: imageDirectory))
        let renderIdentifier = [
            String(Int64(document.renderedAt.timeIntervalSince1970 * 1_000)),
            freshnessCacheToken(document: document, now: now),
        ].joined(separator: "-")
        let cards = Array(document.cards.prefix(Self.maximumCardCount))
        guard !cards.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        var currentImageURLs: [URL] = []
        do {
            let item = TVTopShelfItem(identifier: "provider-portfolio")
            item.title = semanticTitle(document: document, cards: cards, now: now)
            item.expirationDate = document.contentExpirationDate(at: now)
            let action = TVTopShelfAction(url: TVAppRoute.runway.url)
            item.displayAction = action
            item.playAction = action
            let oneXImageURL = try cachedImageURL(
                cards: cards,
                document: document,
                now: now,
                directory: imageDirectory,
                renderIdentifier: renderIdentifier,
                variant: "1x",
                scale: 1
            )
            currentImageURLs.append(oneXImageURL)
            let twoXImageURL = try cachedImageURL(
                cards: cards,
                document: document,
                now: now,
                directory: imageDirectory,
                renderIdentifier: renderIdentifier,
                variant: "2x",
                scale: 2
            )
            currentImageURLs.append(twoXImageURL)
            item.setImageURL(oneXImageURL, for: .screenScale1x)
            item.setImageURL(twoXImageURL, for: .screenScale2x)
            pruneImageDirectory(imageDirectory, preserving: Set(currentImageURLs))
            return TVTopShelfInsetContent(items: [item])
        } catch {
            for url in currentImageURLs where !existingImageURLs.contains(url) {
                try? fileManager.removeItem(at: url)
            }
            throw error
        }
    }

    private func prepareImageDirectory() throws -> URL {
        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directory = cachesDirectory.appending(path: "Context Panel/Top Shelf", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func cachedImageURL(
        cards: [TVTopShelfCard],
        document: TVTopShelfDocument,
        now: Date,
        directory: URL,
        renderIdentifier: String,
        variant: String,
        scale: CGFloat
    ) throws -> URL {
        let cacheScope = [
            "provider-portfolio",
            documentContentHash(document, cards: cards),
            document.isStale(at: now) ? "stale" : "current",
            variant,
        ].joined(separator: "-")
        let imageURL = directory.appending(path: "\(cacheScope)-\(renderIdentifier).png")
        if isUsableImage(at: imageURL) {
            return imageURL
        }

        do {
            try render(
                cards: cards,
                document: document,
                now: now,
                scale: scale
            ).write(to: imageURL, options: .atomic)
            return imageURL
        } catch {
            if let fallbackURL = latestCachedImage(
                in: directory,
                filenamePrefix: "\(cacheScope)-"
            ) {
                return fallbackURL
            }
            throw error
        }
    }

    private func latestCachedImage(in directory: URL, filenamePrefix: String) -> URL? {
        imageFiles(in: directory)
            .filter {
                $0.lastPathComponent.hasPrefix(filenamePrefix)
                    && isUsableImage(at: $0)
            }
            .max { lhs, rhs in
                let left = try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                let right = try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                return (left ?? .distantPast) < (right ?? .distantPast)
            }
    }

    private func imageFiles(in directory: URL) -> [URL] {
        ((try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? [])
            .filter { $0.pathExtension == "png" }
    }

    private func isUsableImage(at url: URL) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return (size ?? 0) > 0
    }

    private func freshnessCacheToken(document: TVTopShelfDocument, now: Date) -> String {
        let seconds = max(Int(now.timeIntervalSince(document.generatedAt)), 0)
        let ageToken: String
        if seconds < 60 {
            ageToken = "now"
        } else if seconds < 60 * 60 {
            ageToken = "m\(seconds / 60)"
        } else if seconds < 24 * 60 * 60 {
            ageToken = "h\(seconds / (60 * 60))"
        } else {
            ageToken = "d\(seconds / (24 * 60 * 60))"
        }
        return document.isStale(at: now) ? "stale-\(ageToken)" : ageToken
    }

    private func documentContentHash(_ document: TVTopShelfDocument, cards: [TVTopShelfCard]) -> String {
        let cardContent = cards.flatMap { card in
            [
                card.id,
                card.title,
                card.headline,
                card.detail,
                card.status.rawValue,
                card.remainingPercent.map(String.init) ?? "unknown",
            ]
        }
        let content = ([
            String(Self.renderVersion),
            String(document.schemaVersion),
            document.snapshotState.rawValue,
            document.presentationMode.rawValue,
        ] + cardContent).joined(separator: "\u{1F}")
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in content.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private func pruneImageDirectory(_ directory: URL, preserving currentURLs: Set<URL>) {
        let files = imageFiles(in: directory)
            .filter { !currentURLs.contains($0) }
            .sorted { lhs, rhs in
                let left = try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                let right = try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                return (left ?? .distantPast) > (right ?? .distantPast)
            }
        for url in files.dropFirst(4) {
            try? fileManager.removeItem(at: url)
        }
    }

    private func render(
        cards: [TVTopShelfCard],
        document: TVTopShelfDocument,
        now: Date,
        scale: CGFloat
    ) throws -> Data {
        let requestedSize = TVTopShelfInsetContent.imageSize
        let size = requestedSize.width > 0 && requestedSize.height > 0
            ? requestedSize
            : CGSize(width: 1920, height: 720)
        return try autoreleasepool {
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = true
            format.preferredRange = .standard
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            let image = renderer.image { context in
                drawBackground(context: context.cgContext, size: size, cards: cards)
                drawContent(size: size, cards: cards, document: document, now: now)
            }
            guard let data = image.pngData() else {
                throw CocoaError(.fileWriteUnknown)
            }
            return data
        }
    }

    private func drawBackground(context: CGContext, size: CGSize, cards: [TVTopShelfCard]) {
        context.setFillColor(UIColor(red: 0.018, green: 0.028, blue: 0.052, alpha: 1).cgColor)
        context.fill(CGRect(origin: .zero, size: size))

        let glowWidth = size.width / CGFloat(max(cards.count, 1))
        for (index, card) in cards.enumerated() {
            let accent = providerColor(card.provider)
            context.setFillColor(accent.withAlphaComponent(0.095).cgColor)
            context.fillEllipse(in: CGRect(
                x: CGFloat(index) * glowWidth - glowWidth * 0.05,
                y: -size.height * 0.72,
                width: glowWidth * 1.1,
                height: size.height * 1.45
            ))
        }

        context.setStrokeColor(UIColor.white.withAlphaComponent(0.07).cgColor)
        context.setLineWidth(max(size.width / 1920, 1))
        context.move(to: CGPoint(x: size.width * 0.05, y: size.height * 0.19))
        context.addLine(to: CGPoint(x: size.width * 0.95, y: size.height * 0.19))
        context.strokePath()
    }

    private func drawContent(
        size: CGSize,
        cards: [TVTopShelfCard],
        document: TVTopShelfDocument,
        now: Date
    ) {
        let scale = size.width / 1920
        let horizontalPadding = 86 * scale
        draw(
            "CONTEXT PANEL",
            in: CGRect(
                x: horizontalPadding,
                y: size.height * 0.075,
                width: 450 * scale,
                height: size.height * 0.06
            ),
            font: .systemFont(ofSize: 28 * scale, weight: .bold),
            color: .white
        )
        draw(
            document.collectionTitle(at: now),
            in: CGRect(
                x: horizontalPadding,
                y: size.height * 0.135,
                width: 700 * scale,
                height: size.height * 0.05
            ),
            font: .systemFont(ofSize: 22 * scale, weight: .medium),
            color: UIColor.white.withAlphaComponent(0.62)
        )
        draw(
            document.freshnessText(at: now),
            in: CGRect(
                x: size.width - horizontalPadding - 430 * scale,
                y: size.height * 0.09,
                width: 430 * scale,
                height: size.height * 0.06
            ),
            font: .monospacedDigitSystemFont(ofSize: 22 * scale, weight: .semibold),
            color: document.isStale(at: now)
                ? UIColor(red: 1, green: 0.79, blue: 0.18, alpha: 1)
                : UIColor.white.withAlphaComponent(0.54),
            alignment: .right
        )

        if cards.count == 1, cards[0].provider == nil {
            drawSetupCard(size: size, card: cards[0], scale: scale)
            return
        }

        let spacing = 26 * scale
        let contentWidth = size.width - 2 * horizontalPadding
        let columnWidth = (contentWidth - spacing * 2) / 3
        let groupWidth = columnWidth * CGFloat(cards.count) + spacing * CGFloat(cards.count - 1)
        let groupOriginX = (size.width - groupWidth) / 2
        let cardOriginY = size.height * 0.268
        let cardHeight = size.height - cardOriginY - size.height * 0.04
        for (index, card) in cards.enumerated() {
            let frame = CGRect(
                x: groupOriginX + CGFloat(index) * (columnWidth + spacing),
                y: cardOriginY,
                width: columnWidth,
                height: cardHeight
            )
            drawProviderCard(
                card,
                in: frame,
                scale: scale,
                isStale: document.isStale(at: now)
            )
        }
    }

    private func drawSetupCard(size: CGSize, card: TVTopShelfCard, scale: CGFloat) {
        let frame = CGRect(x: 86 * scale, y: 182 * scale, width: size.width - 172 * scale, height: 420 * scale)
        UIColor.white.withAlphaComponent(0.055).setFill()
        UIBezierPath(roundedRect: frame, cornerRadius: 34 * scale).fill()
        draw(
            card.headline,
            in: CGRect(x: frame.minX + 54 * scale, y: frame.minY + 92 * scale, width: frame.width - 108 * scale, height: 82 * scale),
            font: .systemFont(ofSize: 54 * scale, weight: .bold),
            color: .white,
            alignment: .center
        )
        draw(
            card.detail,
            in: CGRect(x: frame.minX + 110 * scale, y: frame.minY + 196 * scale, width: frame.width - 220 * scale, height: 70 * scale),
            font: .systemFont(ofSize: 25 * scale, weight: .medium),
            color: UIColor.white.withAlphaComponent(0.68),
            alignment: .center
        )
    }

    private func drawProviderCard(
        _ card: TVTopShelfCard,
        in frame: CGRect,
        scale: CGFloat,
        isStale: Bool
    ) {
        let accent = providerColor(card.provider)
        let displayedStatus = displayStatus(for: card, isStale: isStale)
        accent.withAlphaComponent(isStale ? 0.045 : 0.075).setFill()
        UIBezierPath(roundedRect: frame, cornerRadius: 30 * scale).fill()
        UIColor.white.withAlphaComponent(0.075).setStroke()
        let outline = UIBezierPath(roundedRect: frame.insetBy(dx: 0.5 * scale, dy: 0.5 * scale), cornerRadius: 30 * scale)
        outline.lineWidth = max(scale, 1)
        outline.stroke()

        let inset = 36 * scale
        draw(
            card.provider?.displayName.uppercased() ?? "PROVIDER",
            in: CGRect(x: frame.minX + inset, y: frame.minY + 32 * scale, width: frame.width - 2 * inset, height: 36 * scale),
            font: .systemFont(ofSize: 24 * scale, weight: .bold),
            color: accent
        )
        draw(
            card.headline,
            in: CGRect(x: frame.minX + inset, y: frame.minY + 92 * scale, width: frame.width - 2 * inset, height: 96 * scale),
            font: .systemFont(ofSize: 60 * scale, weight: .bold),
            color: .white
        )
        draw(
            statusText(displayedStatus),
            in: CGRect(x: frame.minX + inset, y: frame.minY + 194 * scale, width: frame.width - 2 * inset, height: 38 * scale),
            font: .systemFont(ofSize: 23 * scale, weight: .semibold),
            color: statusColor(displayedStatus)
        )

        let barFrame = CGRect(
            x: frame.minX + inset,
            y: frame.minY + 274 * scale,
            width: frame.width - 2 * inset,
            height: 12 * scale
        )
        UIColor.white.withAlphaComponent(0.13).setFill()
        UIBezierPath(roundedRect: barFrame, cornerRadius: barFrame.height / 2).fill()
        if let remainingPercent = card.remainingPercent {
            let progress = min(max(CGFloat(remainingPercent) / 100, 0), 1)
            let progressFrame = CGRect(
                x: barFrame.minX,
                y: barFrame.minY,
                width: barFrame.width * progress,
                height: barFrame.height
            )
            accent.withAlphaComponent(isStale ? 0.55 : 1).setFill()
            UIBezierPath(roundedRect: progressFrame, cornerRadius: progressFrame.height / 2).fill()
        }

        draw(
            card.detail,
            in: CGRect(x: frame.minX + inset, y: frame.minY + 324 * scale, width: frame.width - 2 * inset, height: 72 * scale),
            font: .systemFont(ofSize: 21 * scale, weight: .medium),
            color: UIColor.white.withAlphaComponent(0.65)
        )
    }

    private func draw(
        _ text: String,
        in rect: CGRect,
        font: UIFont,
        color: UIColor,
        alignment: NSTextAlignment = .left
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(
            in: rect,
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
        )
    }

    private func semanticTitle(
        document: TVTopShelfDocument,
        cards: [TVTopShelfCard],
        now: Date
    ) -> String {
        let isStale = document.isStale(at: now)
        let cardSummaries = cards.map { card in
            if let provider = card.provider {
                return [
                    provider.displayName,
                    card.headline,
                    statusText(displayStatus(for: card, isStale: isStale)),
                ].joined(separator: ", ")
            }
            return [card.headline, card.detail].filter { !$0.isEmpty }.joined(separator: ", ")
        }
        return ([document.collectionTitle(at: now)] + cardSummaries + [document.freshnessText(at: now)])
            .joined(separator: ". ")
    }

    private func providerColor(_ provider: Provider?) -> UIColor {
        switch provider {
        case .openAI:
            UIColor(red: 0.22, green: 0.82, blue: 0.69, alpha: 1)
        case .anthropic:
            UIColor(red: 0.95, green: 0.52, blue: 0.33, alpha: 1)
        case .google:
            UIColor(red: 0.31, green: 0.64, blue: 1, alpha: 1)
        case nil:
            UIColor(red: 0.58, green: 0.63, blue: 0.72, alpha: 1)
        }
    }

    private func displayStatus(for card: TVTopShelfCard, isStale: Bool) -> UsageStatus {
        if isStale { return .stale }
        return card.remainingPercent == nil && card.status == .healthy ? .unknown : card.status
    }

    private func statusColor(_ status: UsageStatus) -> UIColor {
        switch status {
        case .healthy:
            UIColor(red: 0.39, green: 0.86, blue: 0.43, alpha: 1)
        case .close, .stale:
            UIColor(red: 1, green: 0.79, blue: 0.18, alpha: 1)
        case .limited, .failure:
            UIColor(red: 1, green: 0.48, blue: 0.12, alpha: 1)
        case .unknown, .loading:
            UIColor.white.withAlphaComponent(0.58)
        }
    }

    private func statusText(_ status: UsageStatus) -> String {
        switch status {
        case .healthy:
            "Available"
        case .close:
            "Close to limit"
        case .limited:
            "Limited"
        case .stale:
            "Saved"
        case .unknown:
            "Unknown"
        case .failure:
            "Needs attention"
        case .loading:
            "Refreshing"
        }
    }
}
