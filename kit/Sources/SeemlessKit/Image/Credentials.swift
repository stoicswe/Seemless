import Foundation
import Security

/// The Windows account's password, kept in the user's login Keychain
/// (docs/03 "Shell configuration"), never in plain files on the host.
public enum WindowsCredentials {
    public static let service = "app.seemless.windows-account"

    public enum KeychainError: Error, CustomStringConvertible {
        case status(OSStatus)
        public var description: String {
            "Keychain error \(self.code): \(SecCopyErrorMessageString(code, nil) as String? ?? "unknown")"
        }
        var code: OSStatus { if case .status(let s) = self { return s }; return 0 }
    }

    /// 24 characters from an alphabet without look-alikes or characters that
    /// need escaping in XML or cmd.exe.
    public static func generatePassword(length: Int = 24) -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] })
    }

    /// Stores (or replaces) the Windows password for the VM named `account`.
    public static func store(_ password: String, account: String, username: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrLabel as String] = "Seemless Windows account \(username) (VM \(account))"
        add[kSecAttrComment as String] = "Windows user: \(username)"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public static func load(account: String) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError.status(status) }
        return String(decoding: data, as: UTF8.self)
    }

    public static func delete(account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

/// Windows time zone IDs for common macOS (IANA) zones. Unknown zones fall
/// back to UTC; the guest agent will keep the clock in sync later (docs/06).
public enum WindowsTimeZone {
    static let table: [String: String] = [
        "UTC": "UTC", "GMT": "UTC",
        "America/New_York": "Eastern Standard Time", "America/Detroit": "Eastern Standard Time",
        "America/Toronto": "Eastern Standard Time", "America/Chicago": "Central Standard Time",
        "America/Denver": "Mountain Standard Time", "America/Phoenix": "US Mountain Standard Time",
        "America/Los_Angeles": "Pacific Standard Time", "America/Vancouver": "Pacific Standard Time",
        "America/Anchorage": "Alaskan Standard Time", "Pacific/Honolulu": "Hawaiian Standard Time",
        "America/Sao_Paulo": "E. South America Standard Time", "America/Mexico_City": "Central Standard Time (Mexico)",
        "Europe/London": "GMT Standard Time", "Europe/Dublin": "GMT Standard Time", "Europe/Lisbon": "GMT Standard Time",
        "Europe/Berlin": "W. Europe Standard Time", "Europe/Amsterdam": "W. Europe Standard Time",
        "Europe/Zurich": "W. Europe Standard Time", "Europe/Rome": "W. Europe Standard Time",
        "Europe/Stockholm": "W. Europe Standard Time", "Europe/Vienna": "W. Europe Standard Time",
        "Europe/Paris": "Romance Standard Time", "Europe/Madrid": "Romance Standard Time",
        "Europe/Brussels": "Romance Standard Time", "Europe/Copenhagen": "Romance Standard Time",
        "Europe/Warsaw": "Central European Standard Time", "Europe/Prague": "Central Europe Standard Time",
        "Europe/Helsinki": "FLE Standard Time", "Europe/Kyiv": "FLE Standard Time", "Europe/Athens": "GTB Standard Time",
        "Europe/Istanbul": "Turkey Standard Time", "Europe/Moscow": "Russian Standard Time",
        "Asia/Dubai": "Arabian Standard Time", "Asia/Kolkata": "India Standard Time",
        "Asia/Singapore": "Singapore Standard Time", "Asia/Shanghai": "China Standard Time",
        "Asia/Hong_Kong": "China Standard Time", "Asia/Taipei": "Taipei Standard Time",
        "Asia/Tokyo": "Tokyo Standard Time", "Asia/Seoul": "Korea Standard Time",
        "Australia/Sydney": "AUS Eastern Standard Time", "Australia/Melbourne": "AUS Eastern Standard Time",
        "Australia/Brisbane": "E. Australia Standard Time", "Australia/Perth": "W. Australia Standard Time",
        "Pacific/Auckland": "New Zealand Standard Time",
    ]

    public static func forIANA(_ id: String) -> String { table[id] ?? "UTC" }
    public static var current: String { forIANA(TimeZone.current.identifier) }
}
