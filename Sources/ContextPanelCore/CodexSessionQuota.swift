import Foundation

public struct CodexSessionQuotaObservation: Equatable, Sendable {
    public let observedAt: Date
    public let snapshot: CodexRateLimitSnapshot
}

public enum CodexSessionQuotaError: Error {
    case sharedDirectory
}

/// Reads only quota event fields from bounded tails; never persists session bodies.
/// The owner must select a directory dedicated to one account. Shared or switched
/// login histories cannot establish account attribution and must not be selected.
public enum CodexSessionQuotaReader {
    public static func read(rootDirectory: URL, now: Date) throws -> CodexSessionQuotaObservation? {
        let values = try rootDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              FileManager.default.isReadableFile(atPath: rootDirectory.path) else {
            throw CocoaError(.fileReadNoPermission)
        }
        return latest(rootDirectory: rootDirectory, now: now)
    }

    public static func latest(rootDirectory: URL, now: Date) -> CodexSessionQuotaObservation? {
        var remainingBytes = CodexSessionTelemetryReader.maximumTotalBytes
        var latest: CodexSessionQuotaObservation?
        let decoder = JSONDecoder()
        for url in CodexSessionTelemetryReader.sessionFiles(rootDirectory: rootDirectory, now: now, fileManager: .default) {
            guard remainingBytes > 0 else { break }
            guard let tail = CodexSessionTelemetryReader.readTail(
                url, byteLimit: min(CodexSessionTelemetryReader.maximumFileBytes, remainingBytes)
            ) else { continue }
            remainingBytes -= tail.bytesRead
            for (index, line) in tail.data.split(separator: 0x0A).enumerated() {
                if index == 0 && tail.truncated { continue }
                guard line.count <= CodexSessionTelemetryReader.maximumLineBytes,
                      let event = try? decoder.decode(QuotaEvent.self, from: Data(line)),
                      event.type == "event_msg", event.payload.type == "token_count",
                      let date = ContextPanelDateFormatting.date(from: event.timestamp), date <= now,
                      let quota = event.payload.rateLimits,
                      quota.primary != nil || quota.secondary != nil,
                      latest.map({ date > $0.observedAt }) ?? true
                else { continue }
                latest = CodexSessionQuotaObservation(observedAt: date, snapshot: CodexRateLimitSnapshot(
                    id: "codex", limitName: nil, planType: quota.planType ?? "unknown",
                    primary: quota.primary?.window, secondary: quota.secondary?.window,
                    credits: quota.credits?.snapshot, rateLimitReachedType: nil
                ))
            }
        }
        return latest
    }

    private struct QuotaEvent: Decodable {
        let timestamp: String
        let type: String
        let payload: Payload
    }
    private struct Payload: Decodable {
        let type: String
        let rateLimits: Quota?
        enum CodingKeys: String, CodingKey { case type; case rateLimits = "rate_limits" }
    }
    private struct Quota: Decodable {
        let primary: Window?
        let secondary: Window?
        let planType: String?
        let credits: Credits?
        enum CodingKeys: String, CodingKey { case primary, secondary, credits; case planType = "plan_type" }
    }
    private struct Credits: Decodable {
        let hasCredits: Bool
        let unlimited: Bool
        let balance: String?
        enum CodingKeys: String, CodingKey { case hasCredits = "has_credits", unlimited, balance }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            hasCredits = try container.decodeIfPresent(Bool.self, forKey: .hasCredits) ?? false
            unlimited = try container.decodeIfPresent(Bool.self, forKey: .unlimited) ?? false
            if let value = try? container.decode(String.self, forKey: .balance),
               let number = Double(value), number.isFinite, number >= 0 {
                balance = value
            } else if let number = try? container.decode(Double.self, forKey: .balance), number.isFinite, number >= 0 {
                balance = String(number)
            } else {
                balance = nil
            }
        }
        var snapshot: CodexCreditsSnapshot {
            CodexCreditsSnapshot(hasCredits: hasCredits, unlimited: unlimited, balance: balance)
        }
    }
    private struct Window: Decodable {
        let usedPercent: Double
        let windowMinutes: Int?
        let resetsAt: Double?
        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case windowMinutes = "window_minutes"
            case resetsAt = "resets_at"
        }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            usedPercent = try container.decode(Double.self, forKey: .usedPercent)
            windowMinutes = try container.decodeIfPresent(Int.self, forKey: .windowMinutes)
            resetsAt = try container.decodeIfPresent(Double.self, forKey: .resetsAt)
            guard usedPercent.isFinite, (0...100).contains(usedPercent),
                  windowMinutes.map({ $0 > 0 }) ?? true,
                  resetsAt.map({ $0.isFinite && $0 > 0 }) ?? true else {
                throw ConnectorError.decodingFailure("Invalid quota observation")
            }
        }
        var window: CodexRateLimitWindow {
            CodexRateLimitWindow(usedPercent: usedPercent, windowMinutes: windowMinutes,
                                 resetsAt: resetsAt.map { Date(timeIntervalSince1970: $0) })
        }
    }
}

public struct CodexSessionQuotaConnector: ProviderConnector {
    public let provider: Provider = .openAI
    private let account: LocalProviderAccountConfiguration
    private let loader: @Sendable (Date) throws -> CodexSessionQuotaObservation?

    public init(account: LocalProviderAccountConfiguration,
                loader: @escaping @Sendable (Date) throws -> CodexSessionQuotaObservation?) {
        self.account = account
        self.loader = loader
    }

    public func refresh(now: Date) async -> ConnectorRefreshResult {
        let accountID = ConnectorRedactor.localAccountID(provider: provider, stableID: account.id)
        var limits: [UsageLimit] = []
        var status: UsageStatus = .unknown
        var usageCredits: ProviderUsageCreditSummary?
        var message: String? = "No quota observation in the selected account's session directory."
        do {
            if let observation = try loader(now) {
                let expired = [observation.snapshot.primary, observation.snapshot.secondary]
                    .compactMap { $0?.resetsAt }.contains { $0 <= now }
                let stale = now.timeIntervalSince(observation.observedAt) > SnapshotFreshness.appMaximumAge || expired
                limits = codexUsageLimits(from: observation.snapshot, accountID: accountID,
                                          configuredAccountID: account.id, accountName: account.displayName,
                                          observedAt: observation.observedAt, statusOverride: stale ? .stale : nil)
                usageCredits = observation.snapshot.credits.map {
                    ProviderUsageCreditSummary(hasCredits: $0.hasCredits, unlimited: $0.unlimited,
                                               balance: $0.balance.flatMap(Double.init))
                }
                status = stale ? .stale : UsageSnapshot(generatedAt: now, limits: limits).aggregateStatus
                message = status == .stale ? "Session quota is stale. Run this account in its own harness, then refresh." : nil
            }
        } catch CodexSessionQuotaError.sharedDirectory {
            status = .failure
            message = "This session folder is assigned to multiple accounts. Select an account-specific source; shared history cannot identify the login."
        } catch {
            status = .failure
            message = "The selected session quota directory cannot be read. Select it again in Settings."
        }
        return ConnectorRefreshResult(generatedAt: now, reports: [ProviderConnectorReport(
            provider: provider, accountID: accountID, configuredAccountID: account.id,
            accountName: account.displayName, generatedAt: now, limits: limits,
            usageCredits: usageCredits, status: status, errorMessage: message
        )])
    }
}
