import Foundation
import Security

enum SecureCredentialStoreError: LocalizedError {
    case invalidValue
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidValue:
            return "The API key is empty."
        case .keychain(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "Keychain error: \(message)"
            }
            return "Keychain error \(status)."
        }
    }
}

enum SecureCredentialStore {
    private static let service = "com.bulwark.BulwarkVideoTools.ai-credentials"

    static func value(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    static func setValue(_ value: String, for account: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            throw SecureCredentialStoreError.invalidValue
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw SecureCredentialStoreError.keychain(updateStatus)
        }

        var insertion = query
        insertion.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SecureCredentialStoreError.keychain(addStatus)
        }
    }

    static func removeValue(for account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecureCredentialStoreError.keychain(status)
        }
    }
}
