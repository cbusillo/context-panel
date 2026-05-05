import Foundation
import Testing

@testable import ContextPanelCore

@Test func visibleTextScannerFindsSubscriptionLimitSignals() {
    let text = """
    GPT-5 Thinking unavailable. You have reached your weekly limit.
    Try again in 3h. Plus includes 160 messages every 3 hours.
    """

    let observations = LimitProbeScanner.scanVisibleText(text, provider: .openAI)
    let kinds = Set(observations.map(\.signalKind))

    #expect(kinds.contains(.limitReached))
    #expect(kinds.contains(.relativeDuration))
    #expect(kinds.contains(.messageLimit))
    #expect(kinds.contains(.modelAvailability))
    #expect(kinds.contains(.planLanguage))
}

@Test func responseShapeScannerOnlyReportsCandidateFieldNames() {
    let observations = LimitProbeScanner.scanResponseShape(
        fieldNames: ["id", "email", "message_cap", "reset_at", "avatar", "remaining_messages"],
        provider: .openAI
    )

    #expect(observations.map(\.sanitizedEvidence).contains("message_cap"))
    #expect(observations.map(\.sanitizedEvidence).contains("remaining_messages"))
    #expect(!observations.map(\.sanitizedEvidence).contains("email"))
}

@Test func probeEvidenceRedactsSecretsBeforeStorage() {
    let observation = LimitProbeObservation(
        provider: .openAI,
        observedAt: Date(),
        source: .visibleText,
        signalKind: .resetLanguage,
        confidence: .observed,
        sanitizedEvidence: "Authorization: bearer abc.def.ghi user chris@example.com token=secret"
    )

    #expect(!observation.sanitizedEvidence.localizedCaseInsensitiveContains("abc.def.ghi"))
    #expect(!observation.sanitizedEvidence.localizedCaseInsensitiveContains("chris@example.com"))
    #expect(!observation.sanitizedEvidence.localizedCaseInsensitiveContains("secret"))
    #expect(observation.sanitizedEvidence.localizedCaseInsensitiveContains("[email redacted]"))
}

@Test func markdownReportContainsRedactionStatement() {
    let report = LimitProbeReport(
        provider: .openAI,
        capturedAt: Date(timeIntervalSinceReferenceDate: 1),
        observations: [
            LimitProbeObservation(
                provider: .openAI,
                observedAt: Date(timeIntervalSinceReferenceDate: 1),
                source: .visibleText,
                signalKind: .relativeDuration,
                confidence: .observed,
                sanitizedEvidence: "resets in 3h"
            )
        ]
    )

    #expect(report.markdownSummary.contains("Limit Probe Report"))
    #expect(report.markdownSummary.contains("resets in 3h"))
    #expect(report.markdownSummary.contains("authorization headers"))
}
