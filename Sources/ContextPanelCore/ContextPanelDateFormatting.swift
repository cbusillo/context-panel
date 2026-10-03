import Foundation

extension JSONDecoder {
    public static var contextPanelISO8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            let value = try container.decode(String.self)
            if let date = ContextPanelDateFormatting.date(from: value) {
                return date
            }
            if let seconds = Double(value) {
                return Date(timeIntervalSince1970: seconds)
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected ISO 8601 date string or Unix timestamp"
            )
        }
        return decoder
    }
}

public enum ContextPanelDateFormatting {
    public static func accountReset(_ date: Date, compact: Bool = false,
                                    locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()
        if !compact { style = style.year() }
        style.locale = locale
        style.timeZone = timeZone
        return date.formatted(style)
    }
    public static func resetDeadline(
        _ date: Date, compact: Bool = false,
        locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute()
        if !compact { style = style.year() }
        style.locale = locale
        style.timeZone = timeZone
        return date.formatted(style)
    }

    public static func string(from date: Date) -> String {
        internetDateFormatter().string(from: date)
    }

    public static func date(from value: String) -> Date? {
        internetDateFormatterWithFractionalSeconds().date(from: value)
            ?? internetDateFormatter().date(from: value)
            ?? dateOnlyFormatter().date(from: value)
    }

    private static func internetDateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    private static func internetDateFormatterWithFractionalSeconds() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static func dateOnlyFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter
    }
}
