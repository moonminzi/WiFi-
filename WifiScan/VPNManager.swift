import Foundation
import NetworkExtension
import Security

/// VPN 프로토콜 선택. auto는 IKEv2를 먼저 해 보고 안 붙으면 WireGuard(443)로 넘어간다.
/// unicorn은 서버로 나가지 않는다 — 기기 안에서 SNI 차단만 우회한다(유니콘 HTTPS).
enum VPNProto: String, CaseIterable, Identifiable {
    case auto, ikev2, wireguard, unicorn

    var id: String { rawValue }
    var label: String { self == .wireguard ? "wg" : rawValue }

    /// 우리 터널 확장(WifiScanTunnel)으로 뜨는 프로토콜인지
    var usesTunnel: Bool { self == .wireguard || self == .unicorn }
}

/// 자동 연결(On Demand). 꺼진 서버를 깨우고 바뀐 IP를 따라가는 건 우리 터널만 할 수 있어서 wg로 연결한다.
enum VPNAutoConnect: String, CaseIterable, Identifiable {
    case off, always, wifi

    var id: String { rawValue }
    var label: String { self == .wifi ? "wi-fi" : rawValue }

    var rules: [NEOnDemandRule] {
        switch self {
        case .off:
            return []
        case .always:
            let any = NEOnDemandRuleConnect()
            any.interfaceTypeMatch = .any
            return [any]
        case .wifi:
            let wifi = NEOnDemandRuleConnect()
            wifi.interfaceTypeMatch = .wiFi
            let cellular = NEOnDemandRuleDisconnect()
            cellular.interfaceTypeMatch = .cellular
            return [wifi, cellular]
        }
    }
}

/// VPN 연결 두 가지를 다룬다.
/// - IKEv2: 아이폰 내장 Personal VPN(`NEVPNManager.shared()`), EAP-MSCHAPv2
/// - WireGuard: 앱 확장(WifiScanTunnel, WireGuardKit)을 `NETunnelProviderManager`로 띄움
/// 아이폰은 VPN을 한 번에 하나만 켜므로, 화면에는 켜져 있는 쪽 상태를 보여 준다.
@MainActor
@Observable
final class VPNManager {
    private let manager = NEVPNManager.shared()
    private var tunnel: NETunnelProviderManager?

    private(set) var ikeStatus: NEVPNStatus = .invalid
    private(set) var wgStatus: NEVPNStatus = .invalid
    /// 터널 확장이 어느 모드로 저장돼 있는지(wireguard / unicorn). 상태 줄에 쓴다.
    private(set) var tunnelProto: VPNProto = .wireguard
    /// 설정을 한 번이라도 저장(프로비저닝)했는지.
    private(set) var isConfigured = false
    private(set) var lastError: String?

    /// 현재 연결 상태. 뷰는 이 값으로 버튼/문구를 바꾼다.
    var status: NEVPNStatus {
        if wgStatus.isActive || wgStatus == .disconnecting { return wgStatus }
        if ikeStatus == .invalid, wgStatus != .invalid { return wgStatus }
        return ikeStatus
    }

    /// 지금 켜져 있는 프로토콜(꺼져 있으면 nil)
    var activeProto: VPNProto? {
        if wgStatus.isActive { return tunnelProto }
        if ikeStatus.isActive { return .ikev2 }
        return nil
    }

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
            tunnel = try await NETunnelProviderManager.loadAllFromPreferences().first
            tunnelProto = Self.proto(of: tunnel)
            isConfigured = manager.protocolConfiguration != nil || tunnel != nil
            refreshStatus()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func refreshStatus() {
        ikeStatus = manager.connection.status
        wgStatus = tunnel?.connection.status ?? .invalid
    }

    /// 저장된 터널 설정이 유니콘 HTTPS인지 WireGuard인지
    private static func proto(of tunnel: NETunnelProviderManager?) -> VPNProto {
        let proto = tunnel?.protocolConfiguration as? NETunnelProviderProtocol
        let mode = proto?.providerConfiguration?["mode"] as? String
        return mode == UnicornSettings.mode ? .unicorn : .wireguard
    }

    /// IKEv2가 연결될 때까지 기다린다. 시간 안에 안 되거나 도중에 끊기면 false.
    func waitForIKE(seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        var started = false
        while Date() < deadline {
            refreshStatus()
            switch ikeStatus {
            case .connected: return true
            case .connecting, .reasserting: started = true
            case .disconnected, .invalid: if started { return false }
            default: break
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return false
    }

    /// 서버/사용자/비밀번호로 VPN 설정을 저장한다.
    /// 처음 저장할 때 "VPN 구성 추가" 시스템 허용 창이 한 번 뜬다.
    /// 비밀번호는 평문으로 저장하지 않고 키체인에 넣은 뒤 그 참조만 설정에 연결한다.
    /// - Parameters:
    ///   - server: 접속할 주소(IP).
    ///   - remoteIdentifier: 서버 인증서의 SAN과 같아야 하는 ID. 한국 서버는 IP, 해외 서버는 FQDN.
    ///   - adblock: IKE ID를 adblock.nago로 보내면 서버가 광고·추적 차단 DNS(10.53.53.53)를 준다.
    ///     비밀번호 확인(EAP)은 그대로 사용자 이름으로 한다.
    func save(server: String, remoteIdentifier: String, username: String, password: String,
              fastMode: Bool, adblock: Bool) async throws {
        try await manager.loadFromPreferences()

        let proto = NEVPNProtocolIKEv2()
        proto.serverAddress = server
        proto.remoteIdentifier = remoteIdentifier
        proto.localIdentifier = adblock ? VPNPreset.adblockIdentity : username
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

    /// 켜져 있는 쪽(둘 다 가능)을 끈다. 자동 연결이 켜져 있으면 바로 다시 붙으므로 먼저 끈다.
    func disconnect() async {
        if let saved = try? await NETunnelProviderManager.loadAllFromPreferences().first, saved.isOnDemandEnabled {
            saved.isOnDemandEnabled = false
            try? await saved.saveToPreferences()
            tunnel = saved
        }
        manager.connection.stopVPNTunnel()
        tunnel?.connection.stopVPNTunnel()
    }

    // MARK: WireGuard

    /// 앱에 들어 있는 터널 확장의 번들 ID(재서명하면서 바뀌어도 실제 값을 읽는다)
    private static var tunnelBundleID: String {
        if let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("WifiScanTunnel.appex"),
           let id = Bundle(url: url)?.bundleIdentifier {
            return id
        }
        return (Bundle.main.bundleIdentifier ?? "com.example.wifiscan") + ".tunnel"
    }

    /// WireGuard 설정을 저장한다. 처음 한 번은 "VPN 구성 추가" 허용 창이 뜬다.
    /// - engine: "neptun"(Rust, NordVPN 엔진) 또는 "go"(wireguard-go, 공식 앱과 같은 엔진)
    /// - queue: NepTUN 스레드 사이 대기열 묶음 수(작을수록 다운로드 중 핑이 낮음)
    /// - region, apiKey: 터널 확장이 핸드셰이크가 끊기면 국가 API로 서버를 깨우고 새 주소로 바꿀 때 쓴다.
    /// - killSwitch: 터널이 끊긴 동안 다른 트래픽을 막는다(includeAllNetworks). 확장 자신의 통신은 막히지 않는다.
    /// - allowLAN: 킬 스위치를 켠 상태에서 프린터·AirPlay 같은 같은 망 기기는 터널 밖으로 보낸다.
    ///   킬 스위치가 꺼져 있으면 iOS가 원래 같은 망 트래픽을 터널에 넣지 않는다.
    func saveWireGuard(privateKey: String, address: String, serverPub: String, endpoint: String,
                       dns: [String], engine: String, queue: Int, region: String, apiKey: String,
                       autoConnect: VPNAutoConnect, killSwitch: Bool, allowLAN: Bool) async throws {
        let tunnel = try await NETunnelProviderManager.loadAllFromPreferences().first ?? NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.tunnelBundleID
        proto.serverAddress = endpoint
        proto.providerConfiguration = [
            "mode": "wireguard",
            "privateKey": privateKey,
            "address": address,
            "serverPub": serverPub,
            "endpoint": endpoint,
            "dns": dns,
            "mtu": 1420,
            "engine": engine,
            "queue": queue,
            "region": region,
            "apiKey": apiKey,
        ]
        proto.includeAllNetworks = killSwitch
        proto.excludeLocalNetworks = killSwitch && allowLAN
        tunnel.protocolConfiguration = proto
        tunnel.localizedDescription = "NAGO VPN (WireGuard)"
        tunnel.isEnabled = true
        tunnel.onDemandRules = autoConnect.rules
        tunnel.isOnDemandEnabled = autoConnect != .off
        try await tunnel.saveToPreferences()
        try await tunnel.loadFromPreferences()
        self.tunnel = tunnel
        tunnelProto = .wireguard
        isConfigured = true
        refreshStatus()
    }

    // MARK: 유니콘 HTTPS

    /// 유니콘 HTTPS 설정을 저장한다. 같은 터널 확장을 쓰지만 mode가 달라서
    /// 확장이 WireGuard 대신 SNI 분할 스택을 띄운다. 서버·키·비밀번호가 필요 없다.
    ///
    /// 킬 스위치(includeAllNetworks)는 쓰지 않는다. 확장이 DoH로 직접 나가야 하는데
    /// 모든 통신을 터널로 밀어 넣으면 서로를 기다리며 멈출 수 있다.
    func saveUnicorn(_ settings: UnicornSettings, autoConnect: VPNAutoConnect) async throws {
        let tunnel = try await NETunnelProviderManager.loadAllFromPreferences().first ?? NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.tunnelBundleID
        proto.serverAddress = "on-device"
        proto.providerConfiguration = [
            "mode": UnicornSettings.mode,
            UnicornSettings.configurationKey: settings.configurationValue,
        ]
        proto.includeAllNetworks = false
        proto.excludeLocalNetworks = false
        tunnel.protocolConfiguration = proto
        tunnel.localizedDescription = "NAGO VPN (유니콘 HTTPS)"
        tunnel.isEnabled = true
        tunnel.onDemandRules = autoConnect.rules
        tunnel.isOnDemandEnabled = autoConnect != .off
        try await tunnel.saveToPreferences()
        try await tunnel.loadFromPreferences()
        self.tunnel = tunnel
        tunnelProto = .unicorn
        isConfigured = true
        refreshStatus()
    }

    /// 터널 확장을 시작한다(WireGuard / 유니콘 HTTPS 공통).
    /// 자동 연결을 켜서 저장하면 iOS가 먼저 붙이기 시작할 수 있어서, 이미 시작됐으면 그대로 둔다.
    /// source=app이면 확장은 앱이 방금 받은 주소를 믿고, 없으면(자동 연결) 서버 상태부터 빨리 확인한다.
    func connectTunnel() throws {
        guard let tunnel else { throw NEVPNError(.configurationInvalid) }
        guard !tunnel.connection.status.isActive else { return }
        try tunnel.connection.startVPNTunnel(options: ["source": "app" as NSString])
    }

    struct TunnelReport: Decodable {
        let lines: [String]
        let stats: String?
    }

    /// 켜져 있는 터널 확장의 로그와 상태(핸드셰이크, 주고받은 양). wg가 켜져 있을 때만 온다.
    func tunnelReport() async -> TunnelReport? {
        guard wgStatus.isActive, let session = tunnel?.connection as? NETunnelProviderSession else { return nil }
        return await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(Data("log".utf8)) { data in
                    continuation.resume(returning: data.flatMap { try? JSONDecoder().decode(TunnelReport.self, from: $0) })
                }
            } catch {
                continuation.resume(returning: nil)
            }
        }
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
    /// 이 IKE ID로 접속하면 서버가 광고 차단 DNS를 준다(server/adblock/setup-adblock.sh)
    static let adblockIdentity = "adblock.nago"

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
