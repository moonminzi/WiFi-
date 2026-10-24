import Foundation
import Observation

/// 나라별 실제 왕복 시간. 각 AWS 리전의 DynamoDB `/ping`(인증 없음, 아주 작은 응답)에 한 번 물어 연결을 데우고
/// (TLS 핸드셰이크가 섞여서 버린다) 같은 연결로 두 번 더 재서 빠른 쪽을 쓴다.
@MainActor
@Observable
final class LatencyProbe {
    private(set) var rtt: [VPNRegion: Int] = [:]
    private(set) var measuring = false
    @ObservationIgnored private var lastRun = Date.distantPast

    /// 20초 안에 잰 적이 있으면 건너뛴다(탭을 오가며 여러 번 부르지 않게)
    func measure(force: Bool = false) async {
        if Demo.on {
            rtt = [.kr: 4, .jp: 31, .us: 128, .uk: 247]
            return
        }
        guard !measuring, force || Date().timeIntervalSince(lastRun) > 20 else { return }
        measuring = true
        defer {
            measuring = false
            lastRun = Date()
        }
        await withTaskGroup(of: (VPNRegion, Int?).self) { group in
            for region in VPNRegion.allCases {
                group.addTask { (region, await Self.ping(region)) }
            }
            for await (region, ms) in group {
                rtt[region] = ms
            }
        }
    }

    nonisolated private static func ping(_ region: VPNRegion) async -> Int? {
        await samples(region, count: 2).compactMap { $0 }.min().map { Int($0.rounded()) }
    }

    /// 한 번 데워(TLS 핸드셰이크) 둔 연결로 count번 잰 왕복 시간(ms). 실패한 회는 nil.
    nonisolated static func samples(_ region: VPNRegion, count: Int) async -> [Double?] {
        guard let url = URL(string: "https://dynamodb.\(region.awsRegion).amazonaws.com/ping") else { return [] }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        guard (try? await session.data(from: url)) != nil else { return Array(repeating: nil, count: count) }
        var out: [Double?] = []
        for _ in 0..<count {
            let start = Date()
            if let (_, response) = try? await session.data(from: url), (response as? HTTPURLResponse)?.statusCode == 200 {
                out.append(Date().timeIntervalSince(start) * 1000)
            } else {
                out.append(nil)
            }
        }
        return out
    }
}

/// 밖에서 보이는 내 IP와 나라. Cloudflare의 `/cdn-cgi/trace`(ip=…, loc=JP, colo=NRT 같은 줄)를 읽는다.
/// VPN이 켜져 있으면 나가는 서버의 IP가 나와야 한다 — 나라가 다르면 새고 있는 것.
struct ExitInfo: Equatable {
    let ip: String
    /// ISO 국가 코드(JP, US, GB …)
    let country: String
    /// 응답한 Cloudflare 데이터센터(공항 코드)
    let colo: String

    static func fetch() async -> ExitInfo? {
        if Demo.on {
            return Demo.connected ? ExitInfo(ip: "54.199.12.4", country: "JP", colo: "NRT")
                                  : ExitInfo(ip: "211.36.1.9", country: "KR", colo: "ICN")
        }
        guard let url = URL(string: "https://1.1.1.1/cdn-cgi/trace") else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6)
        request.httpMethod = "GET"
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let text = String(data: data, encoding: .utf8) else { return nil }
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
        }
        guard let ip = fields["ip"] else { return nil }
        return ExitInfo(ip: ip, country: fields["loc"] ?? "??", colo: fields["colo"] ?? "")
    }
}

extension VPNRegion {
    /// 그 나라 서버가 있는 AWS 리전
    var awsRegion: String {
        switch self {
        case .kr: return "ap-northeast-2"
        case .jp: return "ap-northeast-1"
        case .us: return "us-west-2"
        case .uk: return "eu-west-2"
        }
    }

    /// 출구 IP가 이 나라로 보여야 하는 국가 코드
    var countryCode: String {
        switch self {
        case .kr: return "KR"
        case .jp: return "JP"
        case .us: return "US"
        case .uk: return "GB"
        }
    }
}
