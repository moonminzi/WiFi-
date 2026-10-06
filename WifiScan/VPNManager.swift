import Foundation
import NetworkExtension
import Security

/// 아이폰 내장 Personal VPN(IKEv2)을 다루는 얇은 래퍼.
/// 별도의 Packet Tunnel 확장 없이 `NEVPNManager.shared()`로 IKEv2/EAP-MSCHAPv2 연결을 만든다.
@MainActor
@Observable
final class VPNManager {
    private let manager = NEVPNManager.shared()

    /// 현재 연결 상태. 뷰는 이 값으로 버튼/문구를 바꾼다.
    private(set) var status: NEVPNStatus = .invalid
    /// 설정을 한 번이라도 저장(프로비저닝)했는지.
    private(set) var isConfigured = false
    private(set) var lastError: String?

    init() {
        NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
        Task { await reload() }
    }

    /// 저장돼 있는 VPN 설정을 불러와 상태를 맞춘다.
    func reload() async {
        do {
            try await manager.loadFromPreferences()
            isConfigured = manager.protocolConfiguration != nil
            refreshStatus()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func refreshStatus() {
        status = manager.connection.status
    }

    /// 서버/사용자/비밀번호로 VPN 설정을 저장한다.
    /// 처음 저장할 때 "VPN 구성 추가" 시스템 허용 창이 한 번 뜬다.
    /// 비밀번호는 평문으로 저장하지 않고 키체인에 넣은 뒤 그 참조만 설정에 연결한다.
    /// - Parameters:
    ///   - server: 접속할 주소(IP).
    ///   - remoteIdentifier: 서버 인증서의 SAN과 같아야 하는 ID. 한국 서버는 IP, 해외 서버는 FQDN.
    func save(server: String, remoteIdentifier: String, username: String, password: String,
              fastMode: Bool) async throws {
        try await manager.loadFromPreferences()

        let proto = NEVPNProtocolIKEv2()
        proto.serverAddress = server
        proto.remoteIdentifier = remoteIdentifier
        proto.localIdentifier = username
        proto.authenticationMethod = .none          // EAP(사용자 이름/비밀번호)
        proto.useExtendedAuthentication = true
        proto.username = username
        proto.passwordReference = try KeychainHelper.store(password: password, account: username)
        proto.disconnectOnSleep = false
        proto.deadPeerDetectionRate = .medium
        proto.useConfigurationAttributeInternalIPSubnet = false

        if fastMode {
            // iOS 기본값(AES-CBC + HMAC)은 암호화와 인증을 따로 두 번 처리한다.
            // AES-256-GCM은 칩의 하드웨어 AES로 한 번에 처리해서 더 빠르다.
            // 서버 제안(ike=aes256gcm16-prfsha256-ecp256, esp=aes256gcm16-ecp256)과 정확히 맞춘다.
            for sa in [proto.ikeSecurityAssociationParameters, proto.childSecurityAssociationParameters] {
                sa.encryptionAlgorithm = .algorithmAES256GCM
                sa.integrityAlgorithm = .SHA256     // GCM에선 IKE의 PRF로만 쓰인다
                sa.diffieHellmanGroup = .group19    // ecp256
            }
            // 재키(rekey) 때 서버의 esp 제안(ecp256 PFS)과 맞아야 끊기지 않는다.
            proto.enablePFS = true
            // iOS 기본 터널 MTU는 1280. 최대치 1400으로 올리면 패킷당 실어 나르는 양이 ~10% 늘어난다.
            // ESP-in-UDP(GCM) 오버헤드 ~65바이트를 더해도 1500 안에 들어간다.
            proto.mtu = 1400
        }

        manager.protocolConfiguration = proto
        manager.localizedDescription = "NAGO VPN"
        manager.isEnabled = true
        manager.isOnDemandEnabled = false

        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()     // 저장 직후 다시 로드(권장 패턴)
        isConfigured = true
        refreshStatus()
    }

    /// 터널 시작. 설정이 없으면 먼저 save(...)를 호출해야 한다.
    func connect() throws {
        try manager.connection.startVPNTunnel()
    }

    func disconnect() {
        manager.connection.stopVPNTunnel()
    }
}

// MARK: - 상태를 사람이 읽는 문구로

extension NEVPNStatus {
    var koreanLabel: String {
        switch self {
        case .invalid:       return "설정 안 됨"
        case .disconnected:  return "연결 끊김"
        case .connecting:    return "연결 중…"
        case .connected:     return "연결됨"
        case .reasserting:   return "재연결 중…"
        case .disconnecting: return "끊는 중…"
        @unknown default:    return "알 수 없음"
        }
    }

    var isBusy: Bool {
        self == .connecting || self == .disconnecting || self == .reasserting
    }

    var isActive: Bool {
        self == .connected || self == .connecting || self == .reasserting
    }
}

// MARK: - 내장 비밀번호

/// 전달용 IPA에만 들어가는 비밀번호. 레포가 공개라서 소스에는 두지 않고,
/// 빌드한 뒤 Info.plist에 `NAGOPresetPassword`를 넣는다. 없으면 직접 입력/키체인을 쓴다.
enum VPNPreset {
    static var password: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "NAGOPresetPassword") as? String,
              !value.isEmpty else { return nil }
        return value
    }

    /// 서버 API(국가 선택, 대시보드)에 쓸 비밀번호: 내장 값 → 키체인 순.
    static func key(username: String) -> String? {
        if let preset = password { return preset }
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let saved = KeychainHelper.read(account: user), !saved.isEmpty else { return nil }
        return saved
    }
}

// MARK: - 키체인

/// 비밀번호를 키체인에 저장하고, NEVPNProtocol이 요구하는 persistent reference를 돌려준다.
enum KeychainHelper {
    static func store(
        password: String,
        account: String,
        service: String = "com.example.wifiscan.vpn"
    ) throws -> Data {
        let data = Data(password.utf8)

        // 같은 계정의 기존 항목은 지우고 새로 넣는다.
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)

        var add = base
        add[kSecValueData as String] = data
        add[kSecReturnPersistentRef as String] = true
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        var result: CFTypeRef?
        let st = SecItemAdd(add as CFDictionary, &result)
        guard st == errSecSuccess, let ref = result as? Data else {
            throw NSError(
                domain: "Keychain", code: Int(st),
                userInfo: [NSLocalizedDescriptionKey: "비밀번호를 키체인에 저장하지 못했어요 (코드 \(st))."]
            )
        }
        return ref
    }

    /// 저장해 둔 비밀번호를 읽는다. 국가 선택 API 인증에 쓴다.
    static func read(account: String, service: String = "com.example.wifiscan.vpn") -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
