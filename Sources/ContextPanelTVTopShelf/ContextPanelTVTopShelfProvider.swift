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
    private let fileManager = FileManager.default

    func content(document: TVTopShelfDocument, now: Date) throws -> TVTopShelfSectionedContent {
        let imageDirectory = try prepareImageDirectory()
        let existingImageURLs = Set(imageFiles(in: imageDirectory))
        let renderIdentifier = [
            String(Int64(document.renderedAt.timeIntervalSince1970 * 1_000)),
            freshnessCacheToken(document: document, now: now),
        ].joined(separator: "-")
        var currentImageURLs: [URL] = []
        let cards = document.cards.prefix(Self.maximumCardCount)
        guard !cards.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        do {
            let items = try cards.map { card in
                let item = TVTopShelfSectionedItem(identifier: card.id)
                item.title = card.title
                item.imageShape = .hdtv
                item.expirationDate = document.contentExpirationDate(at: now)
                if let actionURL = URL(string: card.actionURLString) {
                    let action = TVTopShelfAction(url: actionURL)
                    item.displayAction = action
                    item.playAction = action
                }
                let oneXImageURL = try cachedImageURL(
                    for: card,
                    document: document,
                    now: now,
                    directory: imageDirectory,
                    renderIdentifier: renderIdentifier,
                    variant: "1x",
                    scale: 1
                )
                currentImageURLs.append(oneXImageURL)
                let twoXImageURL = try cachedImageURL(
                    for: card,
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
                return item
            }
            pruneImageDirectory(imageDirectory, preserving: Set(currentImageURLs))
            let section = TVTopShelfItemCollection(items: items)
            section.title = document.collectionTitle(at: now)
            return TVTopShelfSectionedContent(sections: [section])
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
        for card: TVTopShelfCard,
        document: TVTopShelfDocument,
        now: Date,
        directory: URL,
        renderIdentifier: String,
        variant: String,
        scale: CGFloat
    ) throws -> URL {
        let cardIdentifier = safeFileComponent(card.id)
        let cacheScope = [
            cardIdentifier,
            cardContentHash(card, mode: document.presentationMode),
            document.isStale(at: now) ? "stale" : "current",
            variant,
        ].joined(separator: "-")
        let imageURL = directory.appending(path: "\(cacheScope)-\(renderIdentifier).png")
        if isUsableImage(at: imageURL) {
            return imageURL
        }

        do {
            try render(
                card: card,
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

    private func safeFileComponent(_ value: String) -> String {
        String(value.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? character
                : "-"
        })
    }

    private func cardContentHash(_ card: TVTopShelfCard, mode: TVPresentationMode) -> String {
        let content = [
            card.id,
            card.title,
            card.headline,
            card.detail,
            card.status.rawValue,
            mode.rawValue,
        ].joined(separator: "\u{1F}")
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
        for url in files.dropFirst(18) {
            try? fileManager.removeItem(at: url)
        }
    }

    private func render(
        card: TVTopShelfCard,
        document: TVTopShelfDocument,
        now: Date,
        scale: CGFloat
    ) throws -> Data {
        let requestedSize = TVTopShelfSectionedContent.imageSize(for: .hdtv)
        let size = requestedSize.width > 0 && requestedSize.height > 0
            ? requestedSize
            : CGSize(width: 608, height: 342)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            drawBackground(context: context.cgContext, size: size, card: card)
            drawContent(size: size, card: card, document: document, now: now)
        }
        guard let data = image.pngData() else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    private func drawBackground(context: CGContext, size: CGSize, card: TVTopShelfCard) {
        context.setFillColor(UIColor(red: 0.025, green: 0.035, blue: 0.055, alpha: 1).cgColor)
        context.fill(CGRect(origin: .zero, size: size))

        let accent = providerColor(card.provider)
        context.setFillColor(accent.withAlphaComponent(0.18).cgColor)
        context.fillEllipse(in: CGRect(
            x: size.width * 0.52,
            y: -size.height * 0.55,
            width: size.width * 0.78,
            height: size.width * 0.78
        ))
        context.setFillColor(accent.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: max(size.width * 0.018, 8), height: size.height))
    }

    private func drawContent(
        size: CGSize,
        card: TVTopShelfCard,
        document: TVTopShelfDocument,
        now: Date
    ) {
        let scale = size.width / 640
        let left = 34 * scale
        let right = 30 * scale
        let providerName = card.provider?.displayName.uppercased() ?? "CONTEXT PANEL"
        draw(
            providerName,
            in: CGRect(x: left, y: 26 * scale, width: size.width * 0.55, height: 40 * scale),
            font: .systemFont(ofSize: 25 * scale, weight: .bold),
            color: .white
        )
        draw(
            statusText(card.status),
            in: CGRect(x: size.width * 0.55, y: 27 * scale, width: size.width * 0.4 - right, height: 38 * scale),
            font: .systemFont(ofSize: 21 * scale, weight: .semibold),
            color: statusColor(card.status),
            alignment: .right
        )
        draw(
            card.headline,
            in: CGRect(x: left, y: 83 * scale, width: size.width - left - right, height: 84 * scale),
            font: .systemFont(ofSize: 54 * scale, weight: .bold),
            color: .white
        )

        if let remainingPercent = card.remainingPercent {
            let barFrame = CGRect(
                x: left,
                y: 188 * scale,
                width: size.width - left - right,
                height: 10 * scale
            )
            UIColor.white.withAlphaComponent(0.14).setFill()
            UIBezierPath(roundedRect: barFrame, cornerRadius: barFrame.height / 2).fill()
            let progress = min(max(CGFloat(remainingPercent) / 100, 0), 1)
            let progressFrame = CGRect(
                x: barFrame.minX,
                y: barFrame.minY,
                width: barFrame.width * progress,
                height: barFrame.height
            )
            providerColor(card.provider).setFill()
            UIBezierPath(roundedRect: progressFrame, cornerRadius: progressFrame.height / 2).fill()
        }

        draw(
            card.detail,
            in: CGRect(x: left, y: 222 * scale, width: size.width - left - right, height: 52 * scale),
            font: .systemFont(ofSize: 22 * scale, weight: .medium),
            color: UIColor.white.withAlphaComponent(0.72)
        )
        draw(
            document.freshnessText(at: now),
            in: CGRect(x: left, y: 296 * scale, width: size.width - left - right, height: 30 * scale),
            font: .monospacedDigitSystemFont(ofSize: 17 * scale, weight: .medium),
            color: document.isStale(at: now)
                ? UIColor(red: 1, green: 0.79, blue: 0.18, alpha: 1)
                : UIColor.white.withAlphaComponent(0.48)
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
