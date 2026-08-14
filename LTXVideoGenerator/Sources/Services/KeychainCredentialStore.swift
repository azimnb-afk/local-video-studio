import Foundation
import Security
import Combine

/// Protocol abstracting credential storage for testing without polluting real Keychain.
public protocol CredentialStorageProtocol: Sendable {
    func read(service: String, account: String) -> String?
    func write(_ secret: String, service: String, account: String) -> Bool
    func delete(service: String, account: String) -> Bool
}

/// Native macOS Keychain implementation using Security framework.
public final class KeychainStorageBackend: CredentialStorageProtocol, @unchecked Sendable {
    public static let shared = KeychainStorageBackend()
    public init() {}

    public func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func write(_ secret: String, service: String, account: String) -> Bool {
        guard let data = secret.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        } else if updateStatus == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            return addStatus == errSecSuccess
        }
        return false
    }

    public func delete(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// Centralized manager for persistent credentials stored in macOS Keychain with
/// backward-compatible migration from legacy UserDefaults.
public final class KeychainCredentialStore: ObservableObject, @unchecked Sendable {
    public static let shared = KeychainCredentialStore()

    public static var defaultServiceName: String {
        AppStorageDirectory.keychainService
    }
    public static let legacyServiceName = "com.example.ltxvideogenerator.credentials"
    public static let elevenLabsAccountName = "elevenLabsApiKey"
    public static let legacyElevenLabsUserDefaultsKey = "elevenLabsApiKey"

    public let serviceName: String
    private let storage: CredentialStorageProtocol
    private let userDefaults: UserDefaults
    private let lock = NSLock()
    private var cachedElevenLabsKey: String = ""

    @Published public private(set) var publishedElevenLabsKey: String = ""

    public init(
        storage: CredentialStorageProtocol = KeychainStorageBackend.shared,
        userDefaults: UserDefaults = .standard,
        serviceName: String? = nil
    ) {
        self.storage = storage
        self.userDefaults = userDefaults
        self.serviceName = serviceName ?? Self.defaultServiceName
        self.cachedElevenLabsKey = loadAndMigrateElevenLabsApiKey()
        self.publishedElevenLabsKey = self.cachedElevenLabsKey
    }

    /// Thread-safe getter and setter for ElevenLabs API key.
    public var elevenLabsApiKey: String {
        get {
            lock.lock()
            defer { lock.unlock() }
            return cachedElevenLabsKey
        }
        set {
            setElevenLabsApiKey(newValue)
        }
    }

    public func setElevenLabsApiKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        cachedElevenLabsKey = trimmed
        if trimmed.isEmpty {
            _ = storage.delete(service: serviceName, account: Self.elevenLabsAccountName)
        } else {
            _ = storage.write(trimmed, service: serviceName, account: Self.elevenLabsAccountName)
        }
        // Ensure legacy plaintext UserDefaults is always cleared once set
        userDefaults.removeObject(forKey: Self.legacyElevenLabsUserDefaultsKey)
        lock.unlock()

        if Thread.isMainThread {
            self.publishedElevenLabsKey = trimmed
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.publishedElevenLabsKey = trimmed
            }
        }
    }

    /// Performs idempotent migration from UserDefaults or legacy Keychain to profile Keychain.
    @discardableResult
    public func loadAndMigrateElevenLabsApiKey() -> String {
        // 1. Check current profile Keychain
        if let secret = storage.read(service: serviceName, account: Self.elevenLabsAccountName), !secret.isEmpty {
            if userDefaults.string(forKey: Self.legacyElevenLabsUserDefaultsKey) != nil {
                userDefaults.removeObject(forKey: Self.legacyElevenLabsUserDefaultsKey)
            }
            return secret
        }

        // 2. Check legacy Keychain ONLY if this is the Personal store (Dev must not inherit)
        if !AppStorageDirectory.isDev,
           serviceName != Self.legacyServiceName,
           let legacyKeychainSecret = storage.read(service: Self.legacyServiceName, account: Self.elevenLabsAccountName),
           !legacyKeychainSecret.isEmpty {
            _ = storage.write(legacyKeychainSecret, service: serviceName, account: Self.elevenLabsAccountName)
            if userDefaults.string(forKey: Self.legacyElevenLabsUserDefaultsKey) != nil {
                userDefaults.removeObject(forKey: Self.legacyElevenLabsUserDefaultsKey)
            }
            return legacyKeychainSecret
        }

        // 3. Check legacy UserDefaults ONLY for Personal store
        if !AppStorageDirectory.isDev,
           let legacySecret = userDefaults.string(forKey: Self.legacyElevenLabsUserDefaultsKey), !legacySecret.isEmpty {
            if storage.write(legacySecret, service: serviceName, account: Self.elevenLabsAccountName) {
                userDefaults.removeObject(forKey: Self.legacyElevenLabsUserDefaultsKey)
                return legacySecret
            } else {
                return legacySecret
            }
        }

        return ""
    }
}
