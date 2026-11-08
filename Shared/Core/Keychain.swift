import CryptoKit
import Foundation
import Security

/// Geräte-Token im Schlüsselbund (nur dieses Gerät, nach erster Entsperrung lesbar).
enum Keychain {
    private static let service = "org.homeroll.thread.session"

    static func save(_ value: String, account: String = "session") {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(account: String = "session") -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete(account: String = "session") {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}

/// Gespeicherte Anmeldung (als JSON im Schlüsselbund).
struct Session: Codable, Equatable {
    var server: String
    var token: String
    var deviceId: String
    var user: UserInfo
    /// true = nur im Speicher (Debug-Anmeldung über die Startumgebung)
    var ephemeral: Bool = false

    var serverURL: URL { URL(string: server)! }

    /// Ordnername für die lokale Datenbank: je Server + Konto + Geräte-Anmeldung getrennt.
    var storageKey: String {
        let h = SHA256.hash(data: Data((server + "|" + user.id + "|" + deviceId).utf8))
        return h.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func load() -> Session? {
        guard let s = Keychain.load(), let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: d)
    }

    func store() {
        guard !ephemeral, let d = try? JSONEncoder().encode(self), let s = String(data: d, encoding: .utf8) else { return }
        Keychain.save(s)
    }

    static func clear() { Keychain.delete() }
}

/// Authenticator-Code (RFC 6238) – nur für die Debug-Anmeldung und Tests; die App selbst kennt kein Geheimnis.
enum TOTP {
    static func code(secret: String, date: Date = .now, offset: Int = 0) -> String? {
        guard let key = base32(secret) else { return nil }
        var counter = UInt64(Int(date.timeIntervalSince1970) / 30 + offset).bigEndian
        let msg = Data(bytes: &counter, count: 8)
        let mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: msg, using: SymmetricKey(data: key)))
        let o = Int(mac[19] & 0x0f)
        let v = (UInt32(mac[o] & 0x7f) << 24) | (UInt32(mac[o + 1]) << 16) | (UInt32(mac[o + 2]) << 8) | UInt32(mac[o + 3])
        return String(format: "%06d", v % 1_000_000)
    }

    static func base32(_ s: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, value = 0
        var out = Data()
        for ch in s.uppercased() where ch != "=" && ch != " " {
            guard let i = alphabet.firstIndex(of: ch) else { return nil }
            value = (value << 5) | i
            bits += 5
            if bits >= 8 {
                out.append(UInt8((value >> (bits - 8)) & 0xff))
                bits -= 8
            }
        }
        return out
    }
}
