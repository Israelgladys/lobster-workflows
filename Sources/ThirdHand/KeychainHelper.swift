import Foundation
import Security

enum KeychainHelper {
    private static let legacyPath = NSHomeDirectory() + "/.thirdhand-api-key"
    private static let apiKeyItem = item(service: "com.thirdhand.openrouter", account: "api-key")
    private static let codexItem = item(service: "com.thirdhand.codex", account: "chatgpt-oauth")

    private static func item(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func save(_ data: Data, to query: [String: Any]) throws {
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw ControllerError.invalid("Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error")")
        }
    }

    private static func load(_ query: [String: Any]) -> (OSStatus, Data?) {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        return (status, result as? Data)
    }

    static func saveAPIKey(_ key: String) throws {
        try save(Data(key.utf8), to: apiKeyItem)
        try? FileManager.default.removeItem(atPath: legacyPath)
    }

    static func getAPIKey() -> String? {
        let (status, data) = load(apiKeyItem)
        if status == errSecSuccess, let data {
            return String(data: data, encoding: .utf8)
        }
        guard status == errSecItemNotFound,
              let legacy = try? String(contentsOfFile: legacyPath, encoding: .utf8) else { return nil }
        let key = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        do { try saveAPIKey(key); return key }
        catch { return nil }
    }

    static func delete() {
        SecItemDelete(apiKeyItem as CFDictionary)
        try? FileManager.default.removeItem(atPath: legacyPath)
    }

    static func saveCodexTokens(_ tokens: CodexTokens) throws {
        try save(try JSONEncoder().encode(tokens), to: codexItem)
    }

    static func getCodexTokens() -> CodexTokens? {
        let (status, data) = load(codexItem)
        guard status == errSecSuccess, let data else { return nil }
        return try? JSONDecoder().decode(CodexTokens.self, from: data)
    }

    static func deleteCodexTokens() {
        SecItemDelete(codexItem as CFDictionary)
    }
}
