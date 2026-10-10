import Foundation

/// Isolates preference tests without writing domains that cfprefsd can recreate on disk.
final class InMemoryUserDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    init() {
        super.init(suiteName: "ContextPanelTests.\(UUID().uuidString)")!
    }

    override func object(forKey key: String) -> Any? {
        lock.withLock { values[key] }
    }

    override func string(forKey key: String) -> String? {
        object(forKey: key) as? String
    }

    override func set(_ value: Any?, forKey key: String) {
        lock.withLock { values[key] = value }
    }

    override func set(_ value: Bool, forKey key: String) {
        set(value as Any, forKey: key)
    }

    override func set(_ value: Int, forKey key: String) {
        set(value as Any, forKey: key)
    }

    override func set(_ value: Float, forKey key: String) {
        set(value as Any, forKey: key)
    }

    override func set(_ value: Double, forKey key: String) {
        set(value as Any, forKey: key)
    }

    override func set(_ value: URL?, forKey key: String) {
        set(value as Any?, forKey: key)
    }

    override func removeObject(forKey key: String) {
        lock.withLock { values[key] = nil }
    }
}
