import Foundation
import Security
import SoundingKit

struct AppKeychainSecretStore: AppSecretStore {
    private let service: String
    private let account: String

    init(
        service: String = "dev.sounding.Sounding.acoustid",
        account: String = "acoustid-api-key"
    ) {
        self.service = service
        self.account = account
    }

    func acoustIDKeyStatus() throws -> SoundingAppAcoustIDKeyStatus {
        var query = baseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return .present
        case errSecItemNotFound:
            return .missing
        default:
            throw AppKeychainSecretStoreError(operation: "read AcoustID key status", status: status)
        }
    }

    func saveAcoustIDKey(_ key: String?) throws {
        guard let key else {
            try clearAcoustIDKey()
            return
        }

        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppKeychainSecretStoreError(message: "Enter an AcoustID key before saving.")
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw AppKeychainSecretStoreError(message: "AcoustID key could not be encoded for secure storage.")
        }

        var attributes = baseQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
        if addStatus != errSecDuplicateItem {
            throw AppKeychainSecretStoreError(operation: "save AcoustID key", status: addStatus)
        }

        let updateStatus = SecItemUpdate(
            baseQuery() as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        guard updateStatus == errSecSuccess else {
            throw AppKeychainSecretStoreError(operation: "replace AcoustID key", status: updateStatus)
        }
    }

    func clearAcoustIDKey() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppKeychainSecretStoreError(operation: "clear AcoustID key", status: status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

struct AppKeychainSecretStoreError: Error, CustomStringConvertible, LocalizedError, Sendable {
    var message: String

    init(message: String) {
        self.message = IngestRedaction.redact(message)
    }

    init(operation: String, status: OSStatus) {
        let systemMessage = SecCopyErrorMessageString(status, nil) as String?
        let detail = systemMessage.map { " (\($0))" } ?? ""
        self.init(message: "Secure storage could not \(operation). OSStatus \(status)\(detail)")
    }

    var description: String { message }
    var errorDescription: String? { message }
}
