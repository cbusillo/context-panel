import ContextPanelCore
import Foundation

public enum TVAppRoute: Equatable, Sendable {
    case runway
    case provider(Provider)
    case account(Provider, String)
    case deadlines
    case validationGallery

    public init?(url: URL) {
        guard url.scheme == "contextpaneltv" else { return nil }
        switch url.host {
        case "runway":
            self = .runway
        case "provider":
            guard let provider = Provider(rawValue: url.lastPathComponent) else { return nil }
            if let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "account" })?.value, !id.isEmpty {
                self = .account(provider, id)
            } else { self = .provider(provider) }
        case "deadlines":
            self = .deadlines
        case "validation-gallery":
            guard url.path.isEmpty,
                  url.user == nil,
                  url.password == nil,
                  url.port == nil,
                  url.query == nil,
                  url.fragment == nil
            else { return nil }
            self = .validationGallery
        default:
            return nil
        }
    }

    public var url: URL {
        switch self {
        case .runway:
            return URL(string: "contextpaneltv://runway")!
        case let .provider(provider):
            return URL(string: "contextpaneltv://provider/\(provider.rawValue)")!
        case let .account(provider, id):
            var components = URLComponents(url: TVAppRoute.provider(provider).url, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "account", value: id)]
            return components.url!
        case .deadlines:
            return URL(string: "contextpaneltv://deadlines")!
        case .validationGallery:
            return URL(string: "contextpaneltv://validation-gallery")!
        }
    }
}
