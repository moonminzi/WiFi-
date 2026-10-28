import Foundation

/// nagoing 설정(막힌 망 우회 전송 층).
///
/// WireGuard를 그대로 두고 그 아래에 전송 층을 하나 끼운다. 앱이 이 값을 만들어
/// `providerConfiguration`에 실어 보내고, 터널 확장이 꺼내 nagoing 클라이언트 프록시를 띄운다.
/// 그래서 앱과 확장이 같이 쓰는 파일이다(UnicornSettings·VPNRegion처럼).
///
/// 자세한 설계: 저장소 루트 `NAGOING.md`.
struct NagoingSettings: Codable, Equatable {

    /// 전송 선택. auto는 UDP 443(QUIC 모양)을 먼저 해 보고 막히면 TLS/TCP 443으로 내려간다.
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

    /// 손실 보정(FEC)을 켤지. 지하철·엘리베이터 버스트 손실을 재전송 없이 되살린다.
    var fecEnabled = true
    /// 데이터 k개마다 패리티 1개(= 1/k 추가 전송).
    var fecK = 8
    /// 인터리브 깊이(= 견딜 수 있는 연속 손실 길이).
    var fecGroups = 8
    var prefer: Prefer = .auto
    /// 서버 nagoing 프록시 포트(보통 둘 다 443).
    var udpPort = 443
    var tcpPort = 443
    /// NepTUN이 WG 패킷을 보낼 로컬 포트(기기 안, 127.0.0.1).
    var localPort = 51822
    /// TCP 폴백에서 ClientHello에 넣을 이름.
    var sni = "www.cloudflare.com"

    init() {}

    /// `prefer auto · fec 8/8` 처럼 설정 한 줄(로그/상태 표시용)
    var summary: String {
        var parts = ["prefer \(prefer.label)"]
        parts.append(fecEnabled ? "fec \(fecK)/\(fecGroups)" : "fec off")
        return parts.joined(separator: " · ")
    }

    // MARK: - settings 탭에서 읽어 오기

    /// settings 탭의 @AppStorage 키.
    enum Key {
        static let fec = "nagoFec"
        static let prefer = "nagoPrefer"
    }

    /// 저장된 값으로 설정을 만든다. 손댄 적 없는 항목은 위의 기본값을 그대로 쓴다.
    static func fromDefaults(defaults: UserDefaults = .standard) -> NagoingSettings {
        var settings = NagoingSettings()
        if let value = defaults.object(forKey: Key.fec) as? Bool { settings.fecEnabled = value }
        if let raw = defaults.string(forKey: Key.prefer), let value = Prefer(rawValue: raw) {
            settings.prefer = value
        }
        return settings
    }

    // MARK: - 확장으로 넘기기

    /// providerConfiguration["mode"]가 이 값이면 WireGuard를 nagoing 전송으로 감싼다.
    static let mode = "nagoing"
    /// providerConfiguration에서 이 설정 블록을 담는 키
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
