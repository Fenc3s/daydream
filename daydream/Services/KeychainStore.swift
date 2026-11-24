import Foundation
import Security

enum CredentialAccount: String, CaseIterable, Sendable {
    case openRouterAPIKey = "openRouterAPIKey"
    case deepSeekAPIKey = "deepSeekAPIKey"
    case chatGPTAuthSession = "chatGPTAuthSession"
    case chatGPTHostID = "chatGPTHostID"
    case chatGPTClientID = "chatGPTClientID"

    init(provider: AIProvider) {
        switch provider {
        case .openRouter:
            self = .openRouterAPIKey
        case .deepSeek:
            self = .deepSeekAPIKey
        case .chatGPT:
            self = .chatGPTAuthSession
        }
    }
}

protocol CredentialStoring: Sendable {
    func string(for account: CredentialAccount) -> String?
    func setString(_ value: String, for account: CredentialAccount)
}

struct KeychainStore: CredentialStoring {
    static let defaultService = "com.daydream.app"

    let service: String

    init(service: String = Self.defaultService) {
        self.service = service
    }

    func string(for account: CredentialAccount) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
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

    func setString(_ value: String, for account: CredentialAccount) {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]

        guard !value.isEmpty else {
            SecItemDelete(baseQuery as CFDictionary)
            return
        }

        let data = Data(value.utf8)
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus != errSecItemNotFound {
            SecItemDelete(baseQuery as CFDictionary)
        }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    func removeAll() {
        for account in CredentialAccount.allCases {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account.rawValue,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }
}

/// Isolated credential store used only when `SettingsStore` is initialized with a custom test directory.
final class DirectoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    init(directory: URL) {
        fileURL = directory.appendingPathComponent(".credentials-test.json", isDirectory: false)
    }

    func string(for account: CredentialAccount) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return loadAll()[account.rawValue]
    }

    func setString(_ value: String, for account: CredentialAccount) {
        lock.lock()
        defer { lock.unlock() }
        var entries = loadAll()
        if value.isEmpty {
            entries.removeValue(forKey: account.rawValue)
        } else {
            entries[account.rawValue] = value
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }

    private func loadAll() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return entries
    }
}
