import Foundation
@testable import LTXVideoGeneratorCore

final class MockCredentialStorage: CredentialStorageProtocol, @unchecked Sendable {
    private var store: [String: String] = [:]
    private let lock = NSLock()

    var shouldFailWrites = false

    func key(service: String, account: String) -> String {
        "\(service):\(account)"
    }

    func read(service: String, account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return store[key(service: service, account: account)]
    }

    func write(_ secret: String, service: String, account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if shouldFailWrites { return false }
        store[key(service: service, account: account)] = secret
        return true
    }

    func delete(service: String, account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        store.removeValue(forKey: key(service: service, account: account))
        return true
    }
}

func runKeychainCredentialStoreTests(_ t: TestKit) {
    t.suite("KeychainCredentialStore — CRUD & Migration") {
        let mockDefaultsSuite = "com.ltx.test.keychain.\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: mockDefaultsSuite) else {
            t.check(false, "Failed to create test UserDefaults suite")
            return
        }
        defer {
            testDefaults.removePersistentDomain(forName: mockDefaultsSuite)
        }

        // Test 1: Save and Read
        let mockStorage = MockCredentialStorage()
        let store = KeychainCredentialStore(storage: mockStorage, userDefaults: testDefaults)

        t.checkEqual(store.elevenLabsApiKey, "", "Initial key is empty")

        store.elevenLabsApiKey = "sk-test-api-key-12345"
        t.checkEqual(store.elevenLabsApiKey, "sk-test-api-key-12345", "Key was saved and read back")
        t.checkEqual(
            mockStorage.read(service: KeychainCredentialStore.serviceName, account: KeychainCredentialStore.elevenLabsAccountName),
            "sk-test-api-key-12345",
            "Stored in mock Keychain storage"
        )
        t.check(testDefaults.string(forKey: KeychainCredentialStore.legacyElevenLabsUserDefaultsKey) == nil, "UserDefaults does NOT contain plaintext secret")

        // Test 2: Replace
        store.elevenLabsApiKey = "sk-replaced-key-67890"
        t.checkEqual(store.elevenLabsApiKey, "sk-replaced-key-67890", "Key was replaced")
        t.checkEqual(
            mockStorage.read(service: KeychainCredentialStore.serviceName, account: KeychainCredentialStore.elevenLabsAccountName),
            "sk-replaced-key-67890",
            "Updated in Keychain storage"
        )

        // Test 3: Remove / Clear
        store.elevenLabsApiKey = ""
        t.checkEqual(store.elevenLabsApiKey, "", "Key is cleared")
        t.check(
            mockStorage.read(service: KeychainCredentialStore.serviceName, account: KeychainCredentialStore.elevenLabsAccountName) == nil,
            "Removed from Keychain storage"
        )

        // Test 4: Migration from legacy UserDefaults
        testDefaults.set("legacy-secret-999", forKey: KeychainCredentialStore.legacyElevenLabsUserDefaultsKey)
        let freshStorage = MockCredentialStorage()
        let migratedStore = KeychainCredentialStore(storage: freshStorage, userDefaults: testDefaults)

        t.checkEqual(migratedStore.elevenLabsApiKey, "legacy-secret-999", "Migrated legacy secret into store")
        t.checkEqual(
            freshStorage.read(service: KeychainCredentialStore.serviceName, account: KeychainCredentialStore.elevenLabsAccountName),
            "legacy-secret-999",
            "Written to Keychain storage during migration"
        )
        t.check(
            testDefaults.string(forKey: KeychainCredentialStore.legacyElevenLabsUserDefaultsKey) == nil,
            "Plaintext legacy UserDefaults value removed after successful migration"
        )

        // Test 5: Idempotency — repeated load does not corrupt
        let repeatedLoad = migratedStore.loadAndMigrateElevenLabsApiKey()
        t.checkEqual(repeatedLoad, "legacy-secret-999", "Subsequent load returns same key")

        // Test 6: Failed write preserves legacy UserDefaults value for safety
        let failStorage = MockCredentialStorage()
        failStorage.shouldFailWrites = true
        testDefaults.set("safe-secret-abc", forKey: KeychainCredentialStore.legacyElevenLabsUserDefaultsKey)

        let safeStore = KeychainCredentialStore(storage: failStorage, userDefaults: testDefaults)
        t.checkEqual(safeStore.elevenLabsApiKey, "safe-secret-abc", "Returns secret even if migration write fails")
        t.checkEqual(
            testDefaults.string(forKey: KeychainCredentialStore.legacyElevenLabsUserDefaultsKey),
            "safe-secret-abc",
            "Legacy value preserved in UserDefaults when Keychain write fails"
        )

        // Test 7: Existing Keychain value wins over stale UserDefaults
        let conflictStorage = MockCredentialStorage()
        _ = conflictStorage.write("keychain-authority", service: KeychainCredentialStore.serviceName, account: KeychainCredentialStore.elevenLabsAccountName)
        testDefaults.set("stale-defaults-value", forKey: KeychainCredentialStore.legacyElevenLabsUserDefaultsKey)

        let resolvedStore = KeychainCredentialStore(storage: conflictStorage, userDefaults: testDefaults)
        t.checkEqual(resolvedStore.elevenLabsApiKey, "keychain-authority", "Keychain value takes precedence over stale UserDefaults")
        t.check(
            testDefaults.string(forKey: KeychainCredentialStore.legacyElevenLabsUserDefaultsKey) == nil,
            "Stale UserDefaults value cleaned up"
        )
    }
}
