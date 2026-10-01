import Foundation

public enum CodexHomeBindingError: LocalizedError {
    case missingAuthFile, sharedHome

    public var errorDescription: String? {
        switch self {
        case .missingAuthFile: "Select a Codex home containing auth.json."
        case .sharedHome: "This Codex home is already assigned to another enabled account."
        }
    }
}

/// Only filesystem metadata is inspected. Credential contents remain in the existing adapter.
public enum CodexHomeBinding {
    public static func bind(
        account: LocalProviderAccountConfiguration,
        home: URL,
        siblings: [LocalProviderAccountConfiguration]
    ) throws -> LocalProviderAccountConfiguration {
        let auth = home.appending(path: "auth.json")
        let canonical = auth.resolvingSymlinksInPath().standardizedFileURL
        let values = try? auth.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else { throw CodexHomeBindingError.missingAuthFile }
        for sibling in siblings where sibling.id != account.id && sibling.isEnabled && sibling.provider == .openAI {
            guard let path = sibling.effectiveAuthPath else { continue }
            let source = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            if source.resolvingSymlinksInPath().standardizedFileURL == canonical {
                throw CodexHomeBindingError.sharedHome
            }
        }
        var result = account
        result.authPath = auth.path
        result.codexQuotaPath = nil
        result.codexClient = .codex
        return result
    }
}
