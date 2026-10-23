import Foundation

/// 유니콘 HTTPS 설정.
///
/// SNI 차단 우회를 켤 때 앱이 만들어 `providerConfiguration`에 실어 보내고,
/// 터널 확장이 그대로 꺼내 쓴다. 그래서 앱과 확장이 같이 쓰는 파일이다(VPNRegion처럼).
struct UnicornSettings: Codable, Equatable {

    /// ClientHello를 어떻게 쪼갤지.
    ///
    /// SNI 차단은 TLS 첫 패킷에 평문으로 들어 있는 도메인 이름을 중간 장비가 읽고 끊는 방식이다.
    /// 그 이름이 한 덩어리로 보이지 않게 쪼개 보내면 검사를 통과한다.
    enum Strategy: String, Codable, CaseIterable, Identifiable {
        /// 쪼개지 않고 그대로(비교용)
        case off
        /// TLS 레코드를 여러 개로 나눔
        case record
        /// TCP 패킷을 나눠 보냄
        case segment
        /// 둘 다(기본)
        case both

        var id: String { rawValue }

        var label: String {
            switch self {
            case .off:     return "off"
            case .record:  return "record"
            case .segment: return "segment"
            case .both:    return "both"
            }
        }

        var splitsRecord: Bool { self == .record || self == .both }
        var splitsSegment: Bool { self == .segment || self == .both }
    }

    /// 암호화 DNS(DoH) 서버. SNI 차단은 DNS 변조와 같이 오는 경우가 많다.
    /// 주소(IP)로 바로 붙어서 시스템 DNS가 가로채여도 동작한다.
    enum Resolver: String, Codable, CaseIterable, Identifiable {
        case cloudflare, google, quad9
        /// 암호화 DNS를 쓰지 않고 평문 DNS(설정 탭의 custom dns)로 물어본다.
        case off

        var id: String { rawValue }

        var label: String {
            switch self {
            case .cloudflare: return "cf"
            case .google:     return "google"
            case .quad9:      return "quad9"
            case .off:        return "off"
            }
        }

        /// DoH 요청을 보낼 IP. 도메인을 다시 물어보는 순환을 피하려고 주소를 박아 둔다.
        var address: String {
            switch self {
            case .cloudflare: return "1.1.1.1"
            case .google:     return "8.8.8.8"
            case .quad9:      return "9.9.9.9"
            case .off:        return ""
            }
        }

        /// TLS 인증서 확인에 쓰는 호스트 이름
        var host: String {
            switch self {
            case .cloudflare: return "cloudflare-dns.com"
            case .google:     return "dns.google"
            case .quad9:      return "dns.quad9.net"
            case .off:        return ""
            }
        }

        var path: String { "/dns-query" }
    }

    var strategy: Strategy = .both
    /// 몇 조각으로 나눌지(2~5). 많이 나눌수록 통과할 확률이 오르지만 조금 느려진다.
    var pieces = 2
    /// 도메인 이름(SNI) 글자 사이를 끊을지. 끄면 레코드를 그냥 고르게 나눈다.
    var splitInsideHostname = true
    /// 443 말고 다른 포트에서도 TLS로 보이면 처리할지
    var allPorts = false
    /// QUIC(UDP 443)을 버려서 TLS over TCP로 내려오게 한다. QUIC은 쪼갤 수 없다.
    var blockQUIC = true
    /// IPv6 트래픽도 터널로 받을지. 끄면 IPv6로 나가는 연결은 우회되지 않는다.
    var handleIPv6 = true
    var resolver: Resolver = .cloudflare
    /// DoH가 막혔을 때, 그리고 resolver가 off일 때 쓰는 평문 DNS
    var plainDNS: [String] = ["1.1.1.1"]

    init() {}

    /// 2~5 사이로 맞춘 조각 수
    var normalizedPieces: Int { min(max(pieces, 2), 5) }

    var resolverAddress: String { resolver.address }
    var resolverHost: String { resolver.host }
    var plainDNSAddress: String { plainDNS.first ?? "1.1.1.1" }

    /// `both·4 · cf` 처럼 설정 한 줄(로그/상태 표시용)
    var summary: String {
        var parts = [strategy == .off ? "off" : "\(strategy.label)·\(normalizedPieces)"]
        parts.append("dns \(resolver.label)")
        if allPorts { parts.append("all-ports") }
        if !blockQUIC { parts.append("quic") }
        if !handleIPv6 { parts.append("no-v6") }
        return parts.joined(separator: " · ")
    }

    // MARK: - settings 탭에서 읽어 오기

    /// settings 탭의 @AppStorage 키. 뷰와 이 파일이 같은 값을 보게 한 곳에 모아 둔다.
    enum Key {
        static let strategy = "uniStrategy"
        static let pieces = "uniPieces"
        static let sniCut = "uniSNICut"
        static let allPorts = "uniAllPorts"
        static let blockQUIC = "uniBlockQUIC"
        static let handleIPv6 = "uniIPv6"
        static let resolver = "uniResolver"
    }

    /// 저장된 값으로 설정을 만든다. 손댄 적 없는 항목은 위의 기본값을 그대로 쓴다.
    /// - plainDNS: DoH가 막혔을 때 쓸 평문 DNS(설정 탭의 custom dns).
    static func fromDefaults(plainDNS: [String], defaults: UserDefaults = .standard) -> UnicornSettings {
        var settings = UnicornSettings()
        if let raw = defaults.string(forKey: Key.strategy), let value = Strategy(rawValue: raw) {
            settings.strategy = value
        }
        if let value = defaults.object(forKey: Key.pieces) as? Int { settings.pieces = value }
        if let value = defaults.object(forKey: Key.sniCut) as? Bool { settings.splitInsideHostname = value }
        if let value = defaults.object(forKey: Key.allPorts) as? Bool { settings.allPorts = value }
        if let value = defaults.object(forKey: Key.blockQUIC) as? Bool { settings.blockQUIC = value }
        if let value = defaults.object(forKey: Key.handleIPv6) as? Bool { settings.handleIPv6 = value }
        if let raw = defaults.string(forKey: Key.resolver), let value = Resolver(rawValue: raw) {
            settings.resolver = value
        }
        if !plainDNS.isEmpty { settings.plainDNS = plainDNS }
        return settings
    }

    // MARK: - 확장으로 넘기기

    /// 터널 안에서만 쓰는 주소. 실제로 쓰이지 않는 벤치마크 대역(198.18/15)과
    /// 사설 IPv6에서 골랐다. DNS 주소는 질의를 터널로 끌어오기 위한 가짜 주소이고,
    /// 응답은 UnicornDoH가 만들어 돌려준다.
    enum Tunnel {
        static let ipv4 = "198.18.0.1"
        static let ipv4Mask = "255.255.255.0"
        static let dnsIPv4 = "198.18.0.2"
        static let ipv6 = "fd6e:a1c0:fe0d::1"
        static let ipv6Prefix = 64
        static let dnsIPv6 = "fd6e:a1c0:fe0d::2"
    }

    /// providerConfiguration에서 쓰는 키
    static let configurationKey = "unicorn"
    /// providerConfiguration["mode"]가 이 값이면 WireGuard 대신 유니콘 HTTPS로 뜬다
    static let mode = "unicorn"

    var configurationValue: NSData {
        ((try? JSONEncoder().encode(self)) ?? Data()) as NSData
    }

    static func from(providerConfiguration configuration: [String: Any]?) -> UnicornSettings {
        guard let data = configuration?[configurationKey] as? Data,
              let decoded = try? JSONDecoder().decode(UnicornSettings.self, from: data)
        else { return UnicornSettings() }
        return decoded
    }
}
