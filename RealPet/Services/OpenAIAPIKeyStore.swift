import Foundation
import Security

enum OpenAIAPIKeyStore {
    private static let service = "com.realpet.app.openai"
    private static let imageAccount = "gpt-image"
    private static let legacyMotionAccount = "motion-generation"
    private static let promptMotionAccount = "motion-prompt"
    private static let agnesMotionAccount = "motion-agnes"

    static func load() -> String? {
        load(account: imageAccount)
    }

    /// Prompt optimization stays on the user's OpenAI-compatible service.
    /// Fall back to the older generic service key for upgraded installations.
    static func loadPromptMotionService() -> String? {
        load(account: promptMotionAccount) ?? load()
    }

    /// Agnes owns a distinct direct credential. The legacy motion account is
    /// only a migration fallback for the previously single-key workflow.
    static func loadAgnesMotionService() -> String? {
        load(account: agnesMotionAccount) ?? load(account: legacyMotionAccount)
    }

    static func loadMotionService() -> String? {
        loadAgnesMotionService()
    }

    static func save(_ key: String) throws {
        try save(key, account: imageAccount)
    }

    static func savePromptMotionService(_ key: String) throws {
        try save(key, account: promptMotionAccount)
    }

    static func saveAgnesMotionService(_ key: String) throws {
        try save(key, account: agnesMotionAccount)
    }

    static func saveMotionService(_ key: String) throws {
        try saveAgnesMotionService(key)
    }

    private static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        return key
    }

    private static func save(_ key: String, account: String) throws {
        let data = Data(key.utf8)
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemUpdate(
            identity as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = identity
            item[kSecValueData as String] = data
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus))
            }
        } else if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
