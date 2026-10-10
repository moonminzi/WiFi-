import CryptoKit
import Foundation

/// 앱 안 WireGuard용 이 폰의 키와 주소.
/// 키는 처음 한 번 폰에서 만들어 키체인에 두고, 공개키만 서버 피어 목록에 등록한다(대시보드 Lambda).
/// 같은 키로 다시 등록하면 같은 주소가 오므로, 관리자가 지웠어도 다음 연결 때 저절로 다시 들어간다.
enum WGClient {
    struct Registration {
        let address: String
        let privateKey: String
        let servers: [String: PeerAPI.WGServer]
    }

    private static let keyAccount = "nago-wg-private-key"
    private static let defaults = UserDefaults.standard

    static func privateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        if let saved = KeychainHelper.read(account: keyAccount),
           let data = Data(base64Encoded: saved),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        _ = try KeychainHelper.store(password: key.rawRepresentation.base64EncodedString(), account: keyAccount)
        return key
    }

    private static var savedServers: [String: PeerAPI.WGServer] {
        guard let data = defaults.data(forKey: "wgServers"),
              let servers = try? JSONDecoder().decode([String: PeerAPI.WGServer].self, from: data) else { return [:] }
        return servers
    }

    /// 등록 정보를 돌려준다. 저장된 게 있으면 바로 쓰고 뒤에서 한 번 더 등록해 둔다(지워졌을 때 복구).
    static func registration(apiKey: String, name: String) async throws -> Registration {
        let key = try privateKey()
        let pub = key.publicKey.rawRepresentation.base64EncodedString()
        let priv = key.rawRepresentation.base64EncodedString()
        if defaults.string(forKey: "wgRegisteredPub") == pub,
           let address = defaults.string(forKey: "wgAddress"), !savedServers.isEmpty {
            Task.detached { _ = try? await register(pub: pub, apiKey: apiKey, name: name) }
            return Registration(address: address, privateKey: priv, servers: savedServers)
        }
        let address = try await register(pub: pub, apiKey: apiKey, name: name)
        return Registration(address: address, privateKey: priv, servers: savedServers)
    }

    @discardableResult
    private static func register(pub: String, apiKey: String, name: String) async throws -> String {
        let reply = try await PeerAPI.send(["op": "add", "pub": pub, "name": name], key: apiKey)
        guard let ip = reply.ip else { throw PeerAPI.Failure.server("no address from server") }
        defaults.set(pub, forKey: "wgRegisteredPub")
        defaults.set(ip, forKey: "wgAddress")
        if let servers = reply.servers, let data = try? JSONEncoder().encode(servers) {
            defaults.set(data, forKey: "wgServers")
        }
        return ip
    }
}
