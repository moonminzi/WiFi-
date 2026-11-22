import Foundation

/// nagoing 설정(막힌 망 우회). nagotun(neptun 엔진) 모드에서 켜는 전송 층.
///
/// WireGuard는 그대로 두고 그 아래에 전송 층을 하나 끼운다: NepTUN의 endpoint를 로컬 프록시로 돌리면
/// 프록시가 WG 패킷을 난독화·FEC해 443으로 서버에 보낸다. 앱이 이 값을 만들어 `providerConfiguration`에
/// 실어 보내고 터널 확장이 꺼내 쓴다(UnicornSettings·VPNRegion처럼 앱·확장이 같이 쓰는 파일).
/// 자세한 설계: 저장소 루트 `NAGOING.md`.
struct NagoingSettings: Codable, Equatable {

    /// 전송 선택. auto는 UDP 51821(QUIC 모양)을 먼저 해 보고 막히면 TLS/TCP 443으로 내려간다.
    enum Prefer: String, Codable, CaseIterable, Identifiable {
        case auto, udp, tcp
        var id: String { rawValue }
        var label: String { rawValue }
        /// FFI(nago_nagoing_client_start)에 넘기는 값: 0 auto, 1 udp, 2 tcp.
        var code: Int32 {
            switch self {
            case .auto: return 0
            case .udp:  return 1
            case .tcp:  return 2
            }
        }
    }

    /// 손실 보정(FEC). 지하철·엘리베이터 버스트 손실을 재전송 없이 되살린다.
    var fecEnabled = true
    var fecK = 8
    var fecGroups = 8
    var prefer: Prefer = .auto
    /// 서버 프록시 포트. TCP는 443(HTTPS, 막힌 망의 핵심). UDP는 전용 51821(udp 443은 기존 WG REDIRECT가 가로챔).
    var udpPort = 51821
    var tcpPort = 443
    /// NepTUN이 WG 패킷을 보낼 로컬 포트(기기 안, 127.0.0.1).
    var localPort = 51822
    var sni = "www.cloudflare.com"

    init() {}

    /// `auto · fec 8/8` 처럼 설정 한 줄
    var summary: String {
        var parts = [prefer.label]
        parts.append(fecEnabled ? "fec \(fecK)/\(fecGroups)" : "fec off")
        return parts.joined(separator: " · ")
    }

    // MARK: settings 탭 키

    enum Key {
        static let on = "nagoOn"
        static let prefer = "nagoPrefer"
        static let fec = "nagoFec"
    }

    static func fromDefaults(defaults: UserDefaults = .standard) -> NagoingSettings {
        var s = NagoingSettings()
        if let v = defaults.object(forKey: Key.fec) as? Bool { s.fecEnabled = v }
        if let raw = defaults.string(forKey: Key.prefer), let v = Prefer(rawValue: raw) { s.prefer = v }
        return s
    }

    // MARK: 확장으로 넘기기

    /// providerConfiguration["mode"]가 이 값이면 WireGuard를 nagoing 전송으로 감싼다.
    static let mode = "nagoing"
    static let configurationKey = "nagoing"
    /// 난독화 키. **보안이 아니라 DPI 회피용**이라 모든 클라가 공유한다(진짜 보안은 안쪽 WireGuard).
    /// 서버 nagoing 프록시도 같은 값으로 띄워야 한다.
    static let psk = "nago-obfs-v1"

    var configurationValue: NSData {
        ((try? JSONEncoder().encode(self)) ?? Data()) as NSData
    }

    static func from(providerConfiguration configuration: [String: Any]?) -> NagoingSettings {
        guard let data = configuration?[configurationKey] as? Data,
              let decoded = try? JSONDecoder().decode(NagoingSettings.self, from: data)
        else { return NagoingSettings() }
        return decoded
    }
}
