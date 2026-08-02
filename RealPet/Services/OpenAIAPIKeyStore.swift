import Foundation
import Security

enum OpenAIAPIKeyStore {
    private static let service = "com.realpet.app.openai"
    private static let imageAccount = "gpt-image"
    private static let miniMaxMotionAccount = "motion-minimax"

    static func load() -> String? {
        load(account: imageAccount)
    }

    /// MiniMax H3 is a separate provider. Do not fall back to the legacy
    /// motion credential because existing installations store an Agnes key there.
    static func loadMiniMaxMotionService() -> String? {
        load(account: miniMaxMotionAccount)
    }

    static func save(_ key: String) throws {
        try save(key, account: imageAccount)
    }

    static func saveMiniMaxMotionService(_ key: String) throws {
        try save(key, account: miniMaxMotionAccount)
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
