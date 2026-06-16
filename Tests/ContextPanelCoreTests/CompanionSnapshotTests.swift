import Foundation
import Testing

@testable import ContextPanelCore

@Test func companionSnapshotOmitsSensitiveStoredFields() throws {
    let generatedAt = Date(timeIntervalSince1970: 1_000)
    let stored = StoredUsageSnapshot(
        savedAt: generatedAt,
        snapshot: UsageSnapshot(generatedAt: generatedAt, limits: [
            UsageLimit(
                provider: .openAI,
                accountID: "raw-provider-account-id",
                configuredAccountID: "configured-local-account-id",
                accountName: "Work OpenAI",
                label: "Codex weekly",
                windowLabel: "Weekly",
                modelLabel: "GPT-5.5",
                unit: .percent,
                used: 91,
                limit: 100,
                resetsAt: generatedAt.addingTimeInterval(3_600),
                lastUpdatedAt: generatedAt,
                confidence: .observed,
                statusOverride: .close,
                note: "private local note"
            ),
        ]),
        reports: [
            StoredProviderReport(
                provider: .openAI,
                accountID: "raw-provider-account-id",
                configuredAccountID: "configured-local-account-id",
                accountName: "Work OpenAI",
                generatedAt: generatedAt,
                status: .failure,
                errorMessage: "Token sk-secret-123 read from /Users/chris/.code/auth.json failed"
            ),
        ],
        promptCacheObservations: [
            PromptCacheObservation(
                provider: .openAI,
                accountID: "prompt-cache-account-id",
                accountName: "Every Code",
                observedAt: generatedAt,
                windowLabel: "Last hour",
                tokens: PromptCacheTokenSet(inputTokens: 1_000, cachedInputTokens: 900)
            ),
        ]
    )

    let companion = CompanionSnapshot(storedSnapshot: stored, publishedAt: generatedAt.addingTimeInterval(5))
    let data = try JSONEncoder.contextPanelCompanionEncoder.encode(companion)
    let json = String(decoding: data, as: UTF8.self)

    #expect(json.contains("Work OpenAI"))
    #expect(json.contains("Codex weekly"))
    #expect(json.contains("Every Code"))
    #expect(json.contains("schemaVersion"))
    #expect(json.contains("companionAccountID"))
    #expect(json.contains("raw-provider-account-id") == false)
    #expect(json.contains("configured-local-account-id") == false)
    #expect(json.contains("prompt-cache-account-id") == false)
    #expect(json.contains("sk-secret-123") == false)
    #expect(json.contains("/Users/chris") == false)
    #expect(json.contains("private local note") == false)
    #expect(json.contains("accountID") == false)
    #expect(json.contains("configuredAccountID") == false)
    #expect(json.contains("errorMessage") == false)
    #expect(json.contains("note") == false)

    let roundTrip = try JSONDecoder.contextPanelCompanionDecoder.decode(CompanionSnapshot.self, from: data)
    #expect(roundTrip == companion)
    #expect(roundTrip.schemaVersion == CompanionSnapshot.schemaVersion)
    #expect(roundTrip.limits.first?.status == .close)
    #expect(roundTrip.providerStatuses.first?.status == .failure)
    #expect(roundTrip.promptCacheSummaries.first?.latestHitRate == 0.9)
}

@Test func companionSnapshotKeepsDuplicateAccountNamesDistinctWithSafeIDs() throws {
    let generatedAt = Date(timeIntervalSince1970: 1_500)
    let stored = StoredUsageSnapshot(
        savedAt: generatedAt,
        snapshot: UsageSnapshot(generatedAt: generatedAt, limits: [
            UsageLimit(
                provider: .openAI,
                accountID: "raw-account-a",
                configuredAccountID: "configured-account-a",
                accountName: "Work",
                label: "Weekly",
                unit: .percent,
                used: 10,
                limit: 100
            ),
            UsageLimit(
                provider: .openAI,
                accountID: "raw-account-b",
                configuredAccountID: "configured-account-b",
                accountName: "Work",
                label: "Weekly",
                unit: .percent,
                used: 20,
                limit: 100
            ),
        ]),
        promptCacheObservations: [
            PromptCacheObservation(
                provider: .openAI,
                accountID: "cache-account-a",
                accountName: "Every Code",
                observedAt: generatedAt,
                windowLabel: "Last hour",
                tokens: PromptCacheTokenSet(inputTokens: 1_000, cachedInputTokens: 900)
            ),
            PromptCacheObservation(
                provider: .openAI,
                accountID: "cache-account-b",
                accountName: "Every Code",
                observedAt: generatedAt.addingTimeInterval(1),
                windowLabel: "Last hour",
                tokens: PromptCacheTokenSet(inputTokens: 1_000, cachedInputTokens: 300)
            ),
        ]
    )

    let companion = CompanionSnapshot(storedSnapshot: stored, publishedAt: generatedAt)

    #expect(companion.limits.map(\.accountName) == ["Work", "Work"])
    #expect(Set(companion.limits.map(\.companionAccountID)).count == 2)
    #expect(companion.promptCacheSummaries.map(\.accountName) == ["Every Code", "Every Code"])
    #expect(Set(companion.promptCacheSummaries.map(\.companionAccountID)).count == 2)
}

@Test func companionSnapshotSanitizesPathAndEmailDisplayNames() throws {
    let generatedAt = Date(timeIntervalSince1970: 1_600)
    let stored = StoredUsageSnapshot(
        savedAt: generatedAt,
        snapshot: UsageSnapshot(generatedAt: generatedAt, limits: [
            UsageLimit(
                provider: .openAI,
                accountID: "path-account",
                accountName: "/Users/chris/.code/auth.json",
                label: "Weekly",
                unit: .percent,
                used: 10,
                limit: 100
            ),
            UsageLimit(
                provider: .anthropic,
                accountID: "email-account",
                accountName: "chris@example.com",
                label: "Weekly",
                unit: .percent,
                used: 10,
                limit: 100
            ),
        ])
    )

    let data = try JSONEncoder.contextPanelCompanionEncoder.encode(
        CompanionSnapshot(storedSnapshot: stored, publishedAt: generatedAt)
    )
    let json = String(decoding: data, as: UTF8.self)
    let roundTrip = try JSONDecoder.contextPanelCompanionDecoder.decode(CompanionSnapshot.self, from: data)

    #expect(json.contains("/Users/chris") == false)
    #expect(json.contains("chris@example.com") == false)
    #expect(roundTrip.limits.map(\.accountName).contains("auth.json"))
    #expect(roundTrip.limits.map(\.accountName).contains("[email redacted]"))
}

@Test func companionSnapshotStaysWithinLatestSnapshotSizeBudget() throws {
    let generatedAt = Date(timeIntervalSince1970: 2_000)
    let limits = (0..<75).map { index in
        UsageLimit(
            provider: Provider.allCases[index % Provider.allCases.count],
            accountID: "raw-account-\(index)",
            configuredAccountID: "configured-account-\(index)",
            accountName: "Account \(index)",
            label: "Window \(index)",
            windowLabel: index.isMultiple(of: 2) ? "Weekly" : "5h",
            modelLabel: index.isMultiple(of: 3) ? "Model \(index)" : nil,
            unit: .percent,
            used: index % 100,
            limit: 100,
            resetsAt: generatedAt.addingTimeInterval(Double(index) * 60),
            lastUpdatedAt: generatedAt,
            confidence: .official
        )
    }
    let stored = StoredUsageSnapshot(
        savedAt: generatedAt,
        snapshot: UsageSnapshot(generatedAt: generatedAt, limits: limits)
    )

    let data = try JSONEncoder.contextPanelCompanionEncoder.encode(
        CompanionSnapshot(storedSnapshot: stored, publishedAt: generatedAt)
    )

    #expect(data.count < 500_000)
}

private extension JSONEncoder {
    static var contextPanelCompanionEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var contextPanelCompanionDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
