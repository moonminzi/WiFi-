import Foundation
import NagoTLCore
import Security

/// AI API 키는 기기 키체인에만(저장소·설정 파일에 남지 않게). 제공자마다 따로
enum Keychain {
    static let account = "api-key"

    /// Claude는 예전 이름 그대로(이미 넣은 키가 그대로 보이게)
    static func service(_ p: Provider) -> String { p == .claude ? "nagotl.claude" : "nagotl." + p.rawValue }

    static func key(_ p: Provider) -> String? { load(service(p)) }

    static func setKey(_ value: String?, for p: Provider) {
        if let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
            save(v, service: service(p))
        } else {
            delete(service(p))
        }
    }

    /// Claude 키
    static var apiKey: String? {
        get { key(.claude) }
        set { setKey(newValue, for: .claude) }
    }

    static func save(_ value: String, service: String) {
        delete(service)
        let q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: Data(value.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func load(_ service: String) -> String? {
        let q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ service: String) {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(q as CFDictionary)
    }
}
