import Foundation
import Observation

/// 서버 안의 nago-agent(server/agent) — VPN 안쪽에서만 닿는 10.53.53.53:8053.
/// 누가 묻는지는 터널 주소로 서버가 알아서, 로그인 없이 내 것만 온다(남의 기록은 볼 수 없다).
/// - 광고 차단 통계(오늘 질의·차단 수, 많이 막힌 도메인) — 서버 광고 차단 DNS(--adblock)를 쓸 때만
/// - 실시간 도메인 흐름(live)
/// - 내 광고 차단 강도·내 규칙(AdblockFilter) 맞추기
/// - 친구 집 출구(home exit): 서버에 붙은 집 노드 목록과 지금 출구, 출구 바꾸기
@MainActor
@Observable
final class NagoAgent {
    struct Me: Decodable, Equatable {
        let ip: String
        let dns: DNS?
        let exit: Exit
        let homes: [Home]
        let exitAllowed: Bool
        /// 서버가 지금 이 폰에 쓰는 강도·내 규칙(2.1.9 서버부터. 없으면 nil)
        var filter: Filter? = nil
    }

    struct Filter: Decodable, Equatable {
        let level: String
        let block: [String]
        let allow: [String]

        func same(as v: AdblockFilter.Value) -> Bool {
            level == v.level.rawValue && Set(block) == Set(v.block) && Set(allow) == Set(v.allow)
        }
    }

    struct DNS: Decodable, Equatable {
        let queries: Int
        let blocked: Int
        let top: [Count]
        let sites: [Count]
        let last: Int

        var share: Double { queries > 0 ? Double(blocked) / Double(queries) : 0 }
    }

    /// ["ads.example.com", 12] 모양
    struct Count: Decodable, Equatable, Identifiable {
        let domain: String
        let n: Int
        var id: String { domain }

        init(domain: String, n: Int) {
            self.domain = domain
            self.n = n
        }

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            domain = try c.decode(String.self)
            n = try c.decode(Int.self)
        }
    }

    struct Exit: Decodable, Equatable {
        /// "server" 또는 집 id
        let via: String
        /// 고른 집이 끊겨 서버로 나가는 중이면 false
        let active: Bool
    }

    struct Home: Decodable, Equatable, Identifiable {
        let id: String
        let name: String
        let online: Bool
    }

    struct Item: Decodable, Identifiable, Equatable {
        let s: Int
        let t: TimeInterval
        let d: String
        let b: Bool
        /// 막힌 까닭: "list"(차단 목록) · "mine"(내 규칙) · "cname"(실제 목적지가 차단 목록, extreme)
        var r: String? = nil
        var id: Int { s }
    }

    private struct FeedReply: Decodable {
        let items: [Item]
        let last: Int
    }

    static let base = URL(string: "http://10.53.53.53:8053")!
    /// vpn 탭과 settings(강도·내 규칙을 바꾸면 바로 보냄)가 같이 쓴다
    static let shared = NagoAgent()

    private(set) var me: Me?
    /// live 화면에 쌓인 도메인(최근 500개)
    private(set) var feed: [Item] = []
    private(set) var switching = false
    private(set) var errorText: String?
    private var lastSeq = 0

    private static var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    /// 끊기면 지운다(다음 연결의 서버는 다른 서버일 수 있다)
    func reset() {
        me = nil
        feed = []
        lastSeq = 0
        errorText = nil
    }

    func refresh() async {
        if Demo.on {
            fillDemo()
            return
        }
        guard let me: Me = try? await Self.get("/v1/me") else { return }
        self.me = me
        await syncFilter()
    }

    /// 폰에 저장된 강도·내 규칙이 서버 것과 다르면 보낸다(연결 직후 · refresh마다 · 바꿀 때).
    /// 예전 서버(filter를 안 주는)에는 보내지 않는다
    func syncFilter() async {
        guard !Demo.on, let me, let server = me.filter else { return }
        let local = AdblockFilter.current
        guard !server.same(as: local) else { return }
        do {
            var request = URLRequest(url: Self.base.appendingPathComponent("v1/dns"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try JSONSerialization.data(withJSONObject: local.json)
            let session = Self.session
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            self.me = try JSONDecoder().decode(Me.self, from: data)
            NagoLog.add("adblock \(local.level.rawValue) · \(local.block.count) blocked · \(local.allow.count) allowed")
        } catch {}
    }

    /// live 화면이 열려 있는 동안 1초마다
    func pollFeed() async {
        if Demo.on { return }
        guard let reply: FeedReply = try? await Self.get("/v1/feed?after=\(lastSeq)") else { return }
        lastSeq = max(lastSeq, reply.last)
        guard !reply.items.isEmpty else { return }
        feed.append(contentsOf: reply.items)
        if feed.count > 500 { feed.removeFirst(feed.count - 500) }
    }

    /// 출구 바꾸기: "server" 또는 집 id. wg로 붙어 있을 때만(서버가 판단)
    func setExit(_ via: String) async -> Bool {
        if Demo.on {
            if let me {
                self.me = Me(ip: me.ip, dns: me.dns, exit: Exit(via: via, active: true), homes: me.homes,
                             exitAllowed: true, filter: me.filter)
            }
            return true
        }
        switching = true
        errorText = nil
        defer { switching = false }
        do {
            var request = URLRequest(url: Self.base.appendingPathComponent("v1/exit"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["via": via])
            let session = Self.session
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                errorText = message ?? "http \(code)"
                return false
            }
            me = try JSONDecoder().decode(Me.self, from: data)
            NagoLog.add("exit via \(via)")
            return true
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }

    private static func get<T: Decodable>(_ path: String) async throws -> T {
        let session = Self.session
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: URL(string: path, relativeTo: base)!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// 스크린샷용
    func fillDemo() {
        me = Me(ip: "10.9.0.2",
                dns: DNS(queries: 18_902, blocked: 1_234,
                         top: [Count(domain: "googleads.g.doubleclick.net", n: 212),
                               Count(domain: "app-measurement.com", n: 148),
                               Count(domain: "graph.facebook.com", n: 96),
                               Count(domain: "ad.daum.net", n: 71),
                               Count(domain: "tr.line.me", n: 40)],
                         sites: [], last: 0),
                exit: me?.exit ?? Exit(via: "server", active: true),
                homes: [Home(id: "h240", name: "minji-pc", online: true)],
                exitAllowed: true,
                filter: Filter(level: AdblockFilter.current.level.rawValue, block: AdblockFilter.current.block,
                               allow: AdblockFilter.current.allow))
        if feed.isEmpty {
            let now = Date().timeIntervalSince1970
            let sample: [(String, Bool)] = [
                ("api.apple.com", false), ("googleads.g.doubleclick.net", true), ("www.youtube.com", false),
                ("i.ytimg.com", false), ("app-measurement.com", true), ("graph.instagram.com", false),
                ("ad.daum.net", true), ("m.naver.com", false), ("tr.line.me", true), ("gateway.icloud.com", false),
            ]
            feed = sample.enumerated().map { Item(s: $0.offset + 1, t: now - Double(sample.count - $0.offset) * 2,
                                                  d: $0.element.0, b: $0.element.1,
                                                  r: $0.element.1 ? "list" : nil) }
        }
    }
}
