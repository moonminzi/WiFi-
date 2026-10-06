import Foundation

/// VPN 탭에서 고르는 국가. 국가마다 그 나라 AWS 리전에 IKEv2 서버가 하나씩 있다.
/// 한국 서버는 공인 IP가 고정이고(인증서 ID도 IP), 해외 서버는 켤 때마다 IP가 바뀌어서
/// 인증서 ID를 FQDN(예: jp.nago.vpn)으로 두고 주소는 API로 받아 온다.
enum VPNRegion: String, CaseIterable, Identifiable {
    case kr, jp, us, uk

    var id: String { rawValue }

    var label: String {
        switch self {
        case .kr: return "🇰🇷 한국 (서울)"
        case .jp: return "🇯🇵 일본 (도쿄)"
        case .us: return "🇺🇸 미국 (오리건)"
        case .uk: return "🇬🇧 영국 (런던)"
        }
    }

    var name: String {
        switch self {
        case .kr: return "한국"
        case .jp: return "일본"
        case .us: return "미국"
        case .uk: return "영국"
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
            case .forbidden: return "비밀번호가 맞지 않아요."
            case .badResponse(let code): return "서버 켜기 API 오류 (HTTP \(code))."
            case .timeout: return "서버가 4분 안에 켜지지 않았어요. 잠시 뒤 다시 눌러 주세요."
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
                     ? "\(region.name) 서버가 꺼지는 중이라 끝나면 다시 켤게요…"
                     : "\(region.name) 서버 켜는 중… (1~2분)")
            try await Task.sleep(for: .seconds(4))
        }
        throw APIError.timeout
    }
}
