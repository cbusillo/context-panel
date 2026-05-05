import Foundation

public enum ProbeSource: String, Codable, Equatable, Sendable {
    case visibleText
    case networkMetadata
    case redactedResponseShape
    case manualUserEntry
}

public enum ProbeSignalKind: String, Codable, Equatable, Sendable {
    case resetLanguage
    case relativeDuration
    case messageLimit
    case limitReached
    case modelAvailability
    case planLanguage
    case candidateFieldName
}

public struct LimitProbeObservation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let provider: Provider
    public let observedAt: Date
    public let source: ProbeSource
    public let signalKind: ProbeSignalKind
    public let confidence: UsageConfidence
    public let sanitizedEvidence: String

    public init(
        id: UUID = UUID(),
        provider: Provider,
        observedAt: Date,
        source: ProbeSource,
        signalKind: ProbeSignalKind,
        confidence: UsageConfidence,
        sanitizedEvidence: String
    ) {
        self.id = id
        self.provider = provider
        self.observedAt = observedAt
        self.source = source
        self.signalKind = signalKind
        self.confidence = confidence
        self.sanitizedEvidence = EvidenceRedactor.redact(sanitizedEvidence)
    }
}

public struct LimitProbeReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let provider: Provider
    public let capturedAt: Date
    public let observations: [LimitProbeObservation]
    public let networkEvents: [NetworkProbeEvent]
    public let redactions: [String]

    public init(
        provider: Provider,
        capturedAt: Date,
        observations: [LimitProbeObservation],
        networkEvents: [NetworkProbeEvent] = []
    ) {
        self.schemaVersion = 1
        self.provider = provider
        self.capturedAt = capturedAt
        self.observations = observations
        self.networkEvents = networkEvents
        self.redactions = [
            "cookies",
            "authorization headers",
            "bearer tokens",
            "session identifiers",
            "emails",
            "account identifiers",
            "raw response bodies"
        ]
    }

    public var markdownSummary: String {
        var lines = [
            "# Limit Probe Report",
            "",
            "- Provider: \(provider.displayName)",
            "- Captured: \(capturedAt.ISO8601Format())",
            "- Observations: \(observations.count)",
            "",
            "## Observations"
        ]

        if observations.isEmpty {
            lines.append("- No candidate limit signals found.")
        } else {
            for observation in observations {
                lines.append("- `\(observation.signalKind.rawValue)` from `\(observation.source.rawValue)`: \(observation.sanitizedEvidence)")
            }
        }

        lines.append(contentsOf: [
            "",
            "## Network Candidates"
        ])

        if networkEvents.isEmpty {
            lines.append("- No candidate response shapes found.")
        } else {
            for event in networkEvents {
                let status = event.status.map(String.init) ?? "?"
                let bodySize = event.bodySize.map { "\($0)b" } ?? "unknown size"
                let fields = event.matchedFields.joined(separator: ", ")
                lines.append("- `\(event.method) \(event.pathHint)` status `\(status)`, `\(bodySize)`: \(fields)")
            }
        }

        lines.append(contentsOf: [
            "",
            "## Redactions",
            redactions.map { "- \($0)" }.joined(separator: "\n")
        ])

        return lines.joined(separator: "\n")
    }
}

public struct NetworkProbeEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let observedAt: Date
    public let method: String
    public let pathHint: String
    public let status: Int?
    public let contentType: String?
    public let bodySize: Int?
    public let matchedFields: [String]

    public init(
        id: UUID = UUID(),
        observedAt: Date,
        method: String,
        pathHint: String,
        status: Int?,
        contentType: String?,
        bodySize: Int?,
        matchedFields: [String]
    ) {
        self.id = id
        self.observedAt = observedAt
        self.method = EvidenceRedactor.redact(method)
        self.pathHint = EvidenceRedactor.redactPath(pathHint)
        self.status = status
        self.contentType = EvidenceRedactor.redact(contentType ?? "")
        self.bodySize = bodySize
        self.matchedFields = matchedFields.map(EvidenceRedactor.redact).sorted()
    }
}

public enum LimitProbeScanner {
    private static let patterns: [(ProbeSignalKind, NSRegularExpression)] = [
        (.resetLanguage, regex(#"(?i)\b(reset|resets|refresh|refreshes|available again)\b.{0,80}"#)),
        (.relativeDuration, regex(#"(?i)\b(in\s+)?\d+\s*(m|min|mins|minutes|h|hr|hrs|hour|hours|day|days|week|weeks)\b"#)),
        (.messageLimit, regex(#"(?i)\b\d+[\d,]*\s*(messages?|prompts?)\s*(every|per|/)?\s*\d*\s*(hours?|days?|weeks?)?\b"#)),
        (.limitReached, regex(#"(?i)\b(limit reached|reached your limit|you.ve reached|unavailable|try again)\b.{0,80}"#)),
        (.modelAvailability, regex(#"(?i)\b(GPT|Thinking|fast mode|model picker|available|unavailable)\b.{0,80}"#)),
        (.planLanguage, regex(#"(?i)\b(Free|Plus|Pro|Team|Business|Enterprise|Go)\b.{0,80}"#))
    ]

    public static func scanVisibleText(
        _ text: String,
        provider: Provider,
        observedAt: Date = Date()
    ) -> [LimitProbeObservation] {
        let normalized = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)

        var observations: [LimitProbeObservation] = []
        var seen = Set<String>()

        for (kind, pattern) in patterns {
            for match in pattern.matches(in: normalized, range: range).prefix(8) {
                guard let matchRange = Range(match.range, in: normalized) else { continue }
                let evidence = String(normalized[matchRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                let key = "\(kind.rawValue):\(evidence.lowercased())"
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                observations.append(
                    LimitProbeObservation(
                        provider: provider,
                        observedAt: observedAt,
                        source: .visibleText,
                        signalKind: kind,
                        confidence: .observed,
                        sanitizedEvidence: evidence
                    )
                )
            }
        }

        return observations
    }

    public static func scanResponseShape(
        fieldNames: [String],
        provider: Provider,
        observedAt: Date = Date()
    ) -> [LimitProbeObservation] {
        let candidates = fieldNames.filter { field in
            let lower = field.lowercased()
            return ["limit", "usage", "remaining", "reset", "quota", "message", "model", "plan", "cap"].contains { lower.contains($0) }
        }

        return Array(Set(candidates)).sorted().map { field in
            LimitProbeObservation(
                provider: provider,
                observedAt: observedAt,
                source: .redactedResponseShape,
                signalKind: .candidateFieldName,
                confidence: .observed,
                sanitizedEvidence: field
            )
        }
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            preconditionFailure("Invalid probe regex: \(pattern)")
        }
    }
}

public enum EvidenceRedactor {
    private static let redactionPatterns: [(String, String)] = [
        (#"(?i)bearer\s+[a-z0-9._\-]+"#, "bearer [redacted]"),
        (#"(?i)(authorization|cookie|set-cookie|csrf|session|token)[:=]\s*[^\s,;]+"#, "$1=[redacted]"),
        (#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, "[email redacted]"),
        (#"\bsk-[A-Za-z0-9_\-]{12,}\b"#, "[api key redacted]"),
        (#"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#, "[id]"),
        (#"(?<=\.)[A-Za-z0-9_-]{20,}(?=\.)"#, "[id]")
    ]

    public static func redact(_ value: String) -> String {
        var redacted = value
        for (pattern, replacement) in redactionPatterns {
            redacted = redacted.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return redacted
    }

    public static func redactPath(_ value: String) -> String {
        guard let components = URLComponents(string: value) else {
            return redact(value)
        }
        let path = components.path
            .replacingOccurrences(of: #"/[0-9a-fA-F-]{16,}"#, with: "/[id]", options: .regularExpression)
            .replacingOccurrences(of: #"/[A-Za-z0-9_-]{24,}"#, with: "/[id]", options: .regularExpression)
        return redact(path.isEmpty ? value : path)
    }
}
