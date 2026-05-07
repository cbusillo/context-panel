import Foundation

public enum ClaudeWebUsageParser {
    public static func usageLimits(
        from data: Data,
        accountID: String,
        accountName: String,
        observedAt: Date
    ) throws -> [UsageLimit] {
        let payload = try JSONSerialization.jsonObject(with: data)
        guard let root = payload as? [String: Any] else { return [] }

        let windows: [(key: String, label: String, model: String?)] = [
            ("five_hour", "5-hour", nil),
            ("seven_day", "7-day", nil),
            ("seven_day_opus", "7-day", "Opus"),
            ("seven_day_sonnet", "7-day", "Sonnet"),
            ("seven_day_oauth_apps", "7-day", "OAuth apps"),
        ]

        return windows.compactMap { window in
            guard let object = findObject(named: window.key, in: root) else { return nil }
            let usedPercentage = percentValue(for: ["used_percentage", "utilization"], in: object)
            let remainingPercentage = percentValue(for: ["remaining_percentage"], in: object)
            let used = usedPercentage ?? remainingPercentage.map { max(0, 100 - $0) }
            guard let used else { return nil }

            let roundedUsed = min(max(Int(used.rounded()), 0), 100)
            return UsageLimit(
                id: "anthropic:\(accountID):claude-web:\(window.key)",
                provider: .anthropic,
                accountID: accountID,
                accountName: accountName,
                label: "Claude \(window.label)",
                windowLabel: window.label,
                modelLabel: window.model ?? "Claude subscription",
                unit: .percent,
                used: roundedUsed,
                limit: 100,
                resetsAt: resetDate(in: object),
                lastUpdatedAt: observedAt,
                confidence: .observed,
                note: "source: Claude web usage endpoint; authenticated web session required"
            )
        }
    }

    public static func sanitizedUsageFields(from data: Data) throws -> [String] {
        let payload = try JSONSerialization.jsonObject(with: data)
        return Array(collectUsageFields(payload).sorted())
    }

    private static func findObject(named key: String, in value: Any) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            if let found = dictionary[key] as? [String: Any] {
                return found
            }
            for child in dictionary.values {
                if let found = findObject(named: key, in: child) {
                    return found
                }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = findObject(named: key, in: child) {
                    return found
                }
            }
        }
        return nil
    }

    private static func percentValue(for keys: [String], in object: [String: Any]) -> Double? {
        for key in keys {
            guard let raw = numericValue(object[key]) else { continue }
            return raw <= 1 ? raw * 100 : raw
        }
        return nil
    }

    private static func resetDate(in object: [String: Any]) -> Date? {
        guard let raw = object["resets_at"] ?? object["reset_at"] else { return nil }
        if let number = numericValue(raw) {
            return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000 : number)
        }
        if let string = raw as? String {
            return ISO8601DateFormatter().date(from: string)
        }
        return nil
    }

    private static func numericValue(_ value: Any?) -> Double? {
        switch value {
        case let value as Double:
            value
        case let value as Int:
            Double(value)
        case let value as NSNumber:
            value.doubleValue
        case let value as String:
            Double(value)
        default:
            nil
        }
    }

    private static func collectUsageFields(_ value: Any, prefix: String = "", output: Set<String> = []) -> Set<String> {
        var output = output
        let allowed = [
            "five_hour",
            "seven_day",
            "seven_day_opus",
            "seven_day_sonnet",
            "seven_day_oauth_apps",
            "used_percentage",
            "remaining_percentage",
            "utilization",
            "resets_at",
            "reset_at",
            "rate_limits",
            "usage",
        ]

        if let dictionary = value as? [String: Any] {
            for (key, child) in dictionary {
                let path = prefix.isEmpty ? key : "\(prefix).\(key)"
                if allowed.contains(key) {
                    output.insert(path)
                }
                output = collectUsageFields(child, prefix: path, output: output)
            }
        } else if let array = value as? [Any] {
            for child in array.prefix(3) {
                output = collectUsageFields(child, prefix: prefix, output: output)
            }
        }

        return output
    }
}
