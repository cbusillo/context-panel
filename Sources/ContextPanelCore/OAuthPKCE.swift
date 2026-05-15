import CryptoKit
import Foundation

public struct OAuthPKCEChallenge: Equatable, Sendable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String, challenge: String) {
        self.verifier = verifier
        self.challenge = challenge
    }
}

public enum OAuthPKCE {
    public static func makeChallenge(byteCount: Int = 32) throws -> OAuthPKCEChallenge {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw ProviderCredentialStore.StoreError.unhandledStatus(status)
        }
        return challenge(forVerifier: base64URLEncoded(Data(bytes)))
    }

    public static func challenge(forVerifier verifier: String) -> OAuthPKCEChallenge {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return OAuthPKCEChallenge(
            verifier: verifier,
            challenge: base64URLEncoded(Data(digest))
        )
    }

    private static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
