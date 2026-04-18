import Foundation
import Security

enum AppSettingsStorage {
    private static let bundleID = Bundle.main.bundleIdentifier ?? "com.zachlatta.freeflow"

    private static var storageDirectory: URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return FileManager.default.temporaryDirectory
        }
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "FreeFlow"
        let dir = appSupport.appendingPathComponent(appName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static var settingsFileURL: URL {
        storageDirectory.appendingPathComponent(".settings")
    }

    // MARK: - Public API

    static func load(account: String) -> String? {
        var dict = loadSettings()
        if dict[migrationDoneKey] == nil {
            performMigration(account: account, settings: &dict)
        }
        return dict[account]
    }

    static func save(_ value: String, account: String) {
        var dict = loadSettings()
        dict[account] = value
        writeSettings(dict)
    }

    static func delete(account: String) {
        var dict = loadSettings()
        dict.removeValue(forKey: account)
        writeSettings(dict)
    }

    // MARK: - File I/O

    private static func loadSettings() -> [String: String] {
        let url = settingsFileURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    private static func writeSettings(_ dict: [String: String]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        let url = settingsFileURL
        try? data.write(to: url, options: [.atomic])
        // Restrict to owner-only read/write (0600)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    // MARK: - One-time migration from Keychain

    private static let migrationDoneKey = "keychain_migration_done"

    private static func performMigration(account: String, settings dict: inout [String: String]) {
        if let keychainValue = loadFromKeychain(account: account),
           !keychainValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            dict[account] = keychainValue
            dict[migrationDoneKey] = "true"
            writeSettings(dict)
            deleteFromKeychain(account: account)
        } else {
            dict[migrationDoneKey] = "true"
            writeSettings(dict)
        }
    }

    // MARK: - Legacy Keychain helpers (for migration only)

    private static func loadFromKeychain(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: bundleID,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    private static func deleteFromKeychain(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: bundleID,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
