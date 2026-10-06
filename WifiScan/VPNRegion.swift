import Foundation

/// VPN 탭에서 고르는 국가. 국가마다 그 나라 AWS 리전에 IKEv2 서버가 하나씩 있다.
/// 한국 서버는 공인 IP가 고정이고(인증서 ID도 IP), 해외 서버는 켤 때마다 IP가 바뀌어서
/// 인증서 ID를 FQDN(예: jp.nago.vpn)으로 두고 주소는 API로 받아 온다.
enum VPNRegion: String, CaseIterable, Identifiable {
    case kr, jp, us, uk

    var id: String { rawValue }

    /// `🇯🇵 tokyo · ap-northeast-1` 처럼 보여 줄 한 줄
    var detail: String {
        switch self {
        case .kr: return "🇰🇷 seoul · ap-northeast-2"
        case .jp: return "🇯🇵 tokyo · ap-northeast-1"
        case .us: return "🇺🇸 oregon · us-west-2"
        case .uk: return "🇬🇧 london · eu-west-2"
        }
    }

    /// API가 안 될 때 바로 붙어 볼 주소/ID. 고정 IP인 한국 서버만 있다.
    var fallback: RegionAPI.Target? {
        self == .kr ? RegionAPI.Target(address: "3.38.243.135", identifier: "3.38.243.135", justBooted: false) : nil
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
    }

    enum APIError: LocalizedError {
        case forbidden
        case badResponse(Int)
        case timeout

        var errorDescription: String? {
            switch self {
            case .forbidden: return "403 forbidden: wrong password"
            case .badResponse(let code): return "api error: http \(code)"
            case .timeout: return "timeout: server not up after 4m, retry"
            }
        }
    }

    private struct Status: Decodable {
        let state: String
        let ready: Bool
        let ip: String?
        let id: String
    }

    private static func status(_ region: VPNRegion, key: String) async throws -> Status {
        var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "r", value: region.rawValue)]
        var req = URLRequest(url: comps.url!, timeoutInterval: 15)
        req.setValue(key, forHTTPHeaderField: "x-nago-key")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 403 { throw APIError.forbidden }
        guard code == 200 else { throw APIError.badResponse(code) }
        return try JSONDecoder().decode(Status.self, from: data)
    }

    /// 서버가 꺼져 있으면 켜고, 접속할 수 있을 때까지 기다렸다가 주소/ID를 돌려준다.
    @MainActor
    static func waitUntilReady(_ region: VPNRegion, key: String,
                               progress: (String) -> Void) async throws -> Target {
        let deadline = Date().addingTimeInterval(240)
        var waited = false
        while Date() < deadline {
            let s = try await status(region, key: key)
            if s.ready, let ip = s.ip {
                return Target(address: ip, identifier: s.id, justBooted: waited)
            }
            waited = true
            progress(s.state == "stopping"
                     ? "\(region.rawValue): stopping, will restart…"
                     : "\(region.rawValue): booting… (1-2 min)")
            try await Task.sleep(for: .seconds(4))
        }
        throw APIError.timeout
    }
}
