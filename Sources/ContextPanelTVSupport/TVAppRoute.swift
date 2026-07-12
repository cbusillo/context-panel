import ContextPanelCore
import Foundation

public enum TVAppRoute: Equatable, Sendable {
    case runway
    case provider(Provider)

    public init?(url: URL) {
        guard url.scheme == "contextpaneltv" else { return nil }
        switch url.host {
        case "runway":
            self = .runway
        case "provider":
            guard let provider = Provider(rawValue: url.lastPathComponent) else { return nil }
            self = .provider(provider)
        default:
            return nil
        }
    }

    public var url: URL {
        switch self {
        case .runway:
            URL(string: "contextpaneltv://runway")!
        case let .provider(provider):
            URL(string: "contextpaneltv://provider/\(provider.rawValue)")!
        }
    }
}
