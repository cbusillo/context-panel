import Foundation
import Testing

@testable import ContextPanelCore

@Test func visibleTextScannerFindsSubscriptionLimitSignals() {
    let text = """
    GPT-5 Thinking unavailable. You have reached your weekly limit.
    Try again in 3h. Pro shows 52 percent used in the 5 hour window.
    """

    let observations = LimitProbeScanner.scanVisibleText(text, provider: .openAI)
    let kinds = Set(observations.map(\.signalKind))

    #expect(kinds.contains(.limitReached))
    #expect(kinds.contains(.relativeDuration))
    #expect(kinds.contains(.usagePressure))
    #expect(kinds.contains(.modelAvailability))
    #expect(kinds.contains(.planLanguage))
}

@Test func responseShapeScannerOnlyReportsCandidateFieldNames() {
    let observations = LimitProbeScanner.scanResponseShape(
        fieldNames: ["id", "email", "used_percent", "reset_at", "avatar", "token_pressure"],
        provider: .openAI
    )

    #expect(observations.map(\.sanitizedEvidence).contains("reset_at"))
    #expect(!observations.map(\.sanitizedEvidence).contains("email"))
    #expect(observations.map(\.sanitizedEvidence).contains("used_percent"))
    #expect(observations.map(\.sanitizedEvidence).contains("token_pressure"))
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
        ],
        networkEvents: [
            NetworkProbeEvent(
                observedAt: Date(timeIntervalSinceReferenceDate: 1),
                method: "GET",
                pathHint: "/backend-api/accounts/check",
                status: 200,
                contentType: "application/json",
                bodySize: 256,
                matchedFields: ["default_account_plan_type", "accounts.[id].entitlement.subscription_plan"]
            )
        ]
    )

    #expect(report.markdownSummary.contains("Limit Probe Report"))
    #expect(report.markdownSummary.contains("resets in 3h"))
    #expect(report.markdownSummary.contains("Network Candidates"))
    #expect(report.markdownSummary.contains("/backend-api/accounts/check"))
    #expect(report.markdownSummary.contains("subscription_plan"))
    #expect(report.markdownSummary.contains("authorization headers"))
}

@Test func limitProbeReportStoreWritesGitignoredLocalMarkdownReport() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let report = LimitProbeReport(
        provider: .openAI,
        capturedAt: Date(timeIntervalSinceReferenceDate: 1),
        observations: [
            LimitProbeObservation(
                provider: .openAI,
                observedAt: Date(timeIntervalSinceReferenceDate: 1),
                source: .manualUserEntry,
                signalKind: .resetLanguage,
                confidence: .manual,
                sanitizedEvidence: "resets tomorrow"
            )
        ]
    )
    let reportURL = LimitProbeReportStore.localMarkdownReportURL(provider: .openAI, rootDirectory: directory)
    let store = LimitProbeReportStore(reportURL: reportURL)

    try store.saveMarkdown(report)

    #expect(reportURL.path.hasSuffix("limit-probes/openai/latest.md"))
    #expect(try String(contentsOf: reportURL, encoding: .utf8).contains("resets tomorrow"))
}

@Test func networkProbeEventRedactsPathIdentifiers() {
    let event = NetworkProbeEvent(
        observedAt: Date(),
        method: "GET",
        pathHint: "https://chatgpt.com/backend-api/conversation/abc123def456abc123def456?token=secret",
        status: 200,
        contentType: "application/json",
        bodySize: 120,
        matchedFields: ["reset_at", "used_percent"]
    )

    #expect(event.pathHint == "/backend-api/conversation/[id]")
    #expect(event.matchedFields == ["reset_at", "used_percent"])
}

@Test func networkProbeEventRedactsIdentifiersInsideFieldNames() {
    let event = NetworkProbeEvent(
        observedAt: Date(),
        method: "GET",
        pathHint: "/api/accounts",
        status: 200,
        contentType: "application/json",
        bodySize: 120,
        matchedFields: ["accounts.1e13c5e0-a592-428d-a051-9fe5d6260e38.entitlement.subscription_plan"]
    )

    #expect(event.matchedFields == ["accounts.[id].entitlement.subscription_plan"])
}
