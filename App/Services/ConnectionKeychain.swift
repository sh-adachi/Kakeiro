import Foundation
import Security

enum ConnectionKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "dev.adachi.kakeiro.sync",
         kSecAttrAccount as String: "personal-backend"]
    }

    static func load() throws -> SyncConfiguration? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SyncClientError.message("接続設定をキーチェーンから読み込めません。iPhoneのロック解除後に再度お試しください。") }
        return try JSONDecoder().decode(SyncConfiguration.self, from: data)
    }

    static func save(_ configuration: SyncConfiguration) throws {
        let data = try JSONEncoder().encode(configuration)
        let updates: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let result = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if result == errSecItemNotFound {
            var item = query
            updates.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw SyncClientError.message("接続設定を安全に保存できませんでした。") }
        } else if result != errSecSuccess { throw SyncClientError.message("接続設定を更新できませんでした。") }
    }

    static func remove() throws {
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw SyncClientError.message("接続設定を削除できませんでした。") }
    }
}
