import Foundation

/// VPN 탭에서 고르는 국가. kr jp us uk는 그 나라 AWS 리전에 서버가 하나씩 늘 있다(꺼 두었다가 켬).
/// 한국 서버는 공인 IP가 고정이고(인증서 ID도 IP), 해외 서버는 켤 때마다 IP가 바뀌어서
/// 인증서 ID를 FQDN(예: jp.nago.vpn)으로 두고 주소는 API로 받아 온다.
/// 그 뒤 나라들은 임시 서버(`onDemand`): 고르면 API가 그 리전에 서버를 새로 만들고(WireGuard만, 1분쯤),
/// 30분 안 쓰면 서버가 스스로 지워진다(관리자용·유저용 모두, 한꺼번에 2대까지).
enum VPNRegion: String, CaseIterable, Identifiable {
    case kr, jp, us, uk
    case sg, de, fr, ie, se, ca, br, au
    case `in`

    var id: String { rawValue }

    /// 늘 있는 서버(꺼 두었다가 켬)
    static let fixed: [VPNRegion] = [.kr, .jp, .us, .uk]

    /// 고를 때 서버를 새로 만드는 나라
    var onDemand: Bool { !Self.fixed.contains(self) }

    /// `🇯🇵 tokyo · ap-northeast-1` 처럼 보여 줄 한 줄
    var detail: String { "\(flag) \(cityName) · \(awsRegion)" + (onDemand ? " · on demand" : "") }

    var flag: String {
        switch self {
        case .kr: return "🇰🇷"
        case .jp: return "🇯🇵"
        case .us: return "🇺🇸"
        case .uk: return "🇬🇧"
        case .sg: return "🇸🇬"
        case .de: return "🇩🇪"
        case .fr: return "🇫🇷"
        case .ie: return "🇮🇪"
        case .se: return "🇸🇪"
        case .ca: return "🇨🇦"
        case .br: return "🇧🇷"
        case .au: return "🇦🇺"
        case .in: return "🇮🇳"
        }
    }

    /// 서버가 있는 도시
    var cityName: String {
        switch self {
        case .kr: return "seoul"
        case .jp: return "tokyo"
        case .us: return "oregon"
        case .uk: return "london"
        case .sg: return "singapore"
        case .de: return "frankfurt"
        case .fr: return "paris"
        case .ie: return "dublin"
        case .se: return "stockholm"
        case .ca: return "montreal"
        case .br: return "são paulo"
        case .au: return "sydney"
        case .in: return "mumbai"
        }
    }

    /// 그 나라 서버가 있는 AWS 리전
    var awsRegion: String {
        switch self {
        case .kr: return "ap-northeast-2"
        case .jp: return "ap-northeast-1"
        case .us: return "us-west-2"
        case .uk: return "eu-west-2"
        case .sg: return "ap-southeast-1"
        case .de: return "eu-central-1"
        case .fr: return "eu-west-3"
        case .ie: return "eu-west-1"
        case .se: return "eu-north-1"
        case .ca: return "ca-central-1"
        case .br: return "sa-east-1"
        case .au: return "ap-southeast-2"
        case .in: return "ap-south-1"
        }
    }

    /// API가 안 될 때 바로 붙어 볼 주소/ID. 고정 IP인 한국 서버만 있다.
    var fallback: RegionAPI.Target? {
        self == .kr ? RegionAPI.Target(address: "3.38.243.135", identifier: "3.38.243.135", justBooted: false,
                                       wgPub: nil, wgPort: 443) : nil
    }
}

/// 국가별 서버를 켜고 지금 주소를 받아 오는 API (AWS Lambda).
/// 인증은 VPN 비밀번호로 한다(서버는 해시만 들고 있음).
enum RegionAPI {
    static let endpoint = URL(string: "https://wqzk1bnms3.execute-api.ap-northeast-2.amazonaws.com/region")!

    struct Target {
        let address: String
        let identifier: String
        /// 이번에 꺼져 있던 서버를 켠 경우. IKE 데몬이 완전히 뜰 때까지 조금 더 기다린다.
        let justBooted: Bool
        /// 그 서버의 WireGuard 공개키와 포트(443 → 서버에서 51820으로)
        let wgPub: String?
        let wgPort: Int
    }

    enum APIError: LocalizedError {
        case forbidden
        case badResponse(Int)
        case timeout
        /// 임시 서버가 이미 최대 개수만큼 떠 있다
        case tooManyServers

        var errorDescription: String? {
            switch self {
            case .forbidden: return "403 forbidden: wrong password"
            case .badResponse(let code): return "api error: http \(code)"
            case .timeout: return "timeout: server not up after 4m, retry"
            case .tooManyServers: return "409: 2 temp servers already up · they delete after 30m idle"
            }
        }
    }

    private struct Status: Decodable {
        let state: String
        let ready: Bool
        let ip: String?
        let id: String
        let wgPub: String?
        let wgPort: Int?
    }

    private static func status(_ region: VPNRegion, key: String) async throws -> Status {
        var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "r", value: region.rawValue)]
        // 임시 서버를 처음 만드는 요청은 10초 가까이 걸린다
        var req = URLRequest(url: comps.url!, timeoutInterval: region.onDemand ? 28 : 15)
        req.setValue(key, forHTTPHeaderField: "x-nago-key")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 403 { throw APIError.forbidden }
        if code == 409 { throw APIError.tooManyServers }
        guard code == 200 else { throw APIError.badResponse(code) }
        return try JSONDecoder().decode(Status.self, from: data)
    }

    /// 서버가 꺼져 있으면 켜고, 접속할 수 있을 때까지 기다렸다가 주소/ID를 돌려준다.
    /// 해외 서버는 켜지는 동안 요청이 한두 번 실패해도(앱 전환, 망 전환, 5xx) 마감까지 계속 묻는다.
    /// 한국 서버는 고정 IP로 바로 넘어갈 수 있게 첫 실패에서 멈춘다.
    @MainActor
    static func waitUntilReady(_ region: VPNRegion, key: String,
                               progress: (String) -> Void) async throws -> Target {
        let deadline = Date().addingTimeInterval(240)
        var waited = false
        var lastError: Error?
        while true {
            do {
                let s = try await status(region, key: key)
                if s.ready, let ip = s.ip {
                    return Target(address: ip, identifier: s.id, justBooted: waited,
                                  wgPub: s.wgPub, wgPort: s.wgPort ?? 443)
                }
                lastError = nil
                switch s.state {
                case "stopping": progress("\(region.rawValue): stopping → restart…")
                case "creating": progress("\(region.rawValue): new server · ~1m")
                default: progress("\(region.rawValue): booting…")
                }
            } catch APIError.forbidden {
                throw APIError.forbidden
            } catch APIError.tooManyServers {
                throw APIError.tooManyServers
            } catch APIError.badResponse(let code) where (400..<500).contains(code) && code != 429 {
                throw APIError.badResponse(code)
            } catch {
                try Task.checkCancellation()
                if region.fallback != nil { throw error }
                lastError = error
                progress("\(region.rawValue): api retry… (\(error.localizedDescription))")
            }
            waited = true
            // 마감을 잠자기 전에 본다. 앱이 오래 백그라운드에 있다 돌아와도 마지막으로 한 번은 더 묻는다.
            if Date() >= deadline { break }
            try await Task.sleep(for: .seconds(4))
        }
        throw lastError ?? APIError.timeout
    }
}
