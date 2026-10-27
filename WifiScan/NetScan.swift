import Foundation
import Network
import Observation
import Security

/// 지금 붙어 있는 네트워크(공용 와이파이 등)를 검사한다. 하나씩 차례로 돌며 결과가 한 줄씩 쌓인다.
/// - link: 회선 종류·IPv4/IPv6·데이터 절약
/// - portal: captive.apple.com이 그대로 오는지(로그인 창·HTTP 바꿔치기)
/// - dns: one.one.one.one이 1.1.1.1로 오는지(답 바꿔치기)
/// - nxdomain: 없는 이름에 주소를 주는지(광고·포털 DNS)
/// - doh: 암호화 DNS(1.1.1.1 DoH)가 열려 있는지
/// - tls: apple.com 인증서가 시스템 루트로 이어지는지(사용자가 넣은 루트면 엿볼 수 있음)
/// - ipv6: VPN이 켜져 있을 때 IPv6로 새는지
/// - exit: 밖에서 보이는 IP·나라
/// - quality: 가장 가까운 서버까지 왕복·흔들림·손실
@MainActor
@Observable
final class NetScan {
    enum Level: Int, Sendable {
        case pass, info, warn, fail
    }

    struct Check: Identifiable, Sendable {
        let id: String
        let detail: String
        let level: Level
    }

    private(set) var checks: [Check] = []
    private(set) var running = false
    private(set) var finishedAt: Date?
    /// 지금 보는 검사 이름(레이더 아래 한 줄)
    private(set) var current: String?

    static let order = ["link", "portal", "dns", "nxdomain", "doh", "tls", "ipv6", "exit", "quality"]

    var score: Int {
        let penalty = checks.reduce(0) { sum, check in
            switch check.level {
            case .fail: return sum + 35
            case .warn: return sum + 12
            default: return sum
            }
        }
        return max(0, 100 - penalty)
    }

    var grade: String {
        switch score {
        case 90...: return "A"
        case 75..<90: return "B"
        case 55..<75: return "C"
        case 35..<55: return "D"
        default: return "F"
        }
    }

    var hasProblems: Bool { checks.contains { $0.level == .warn || $0.level == .fail } }

    /// - Parameters:
    ///   - vpnOn: 지금 VPN이 켜져 있는지(ipv6·exit 판정이 달라진다)
    ///   - expected: 켜져 있다면 나가야 하는 나라
    func run(vpnOn: Bool, expected: VPNRegion?) async {
        guard !running else { return }
        running = true
        checks = []
        finishedAt = nil
        defer {
            running = false
            current = nil
            finishedAt = Date()
        }
        if Demo.on {
            for check in Self.demoChecks {
                current = check.id
                try? await Task.sleep(for: .milliseconds(120))
                checks.append(check)
            }
            return
        }

        current = "link"
        let path = await Probes.currentPath()
        add(Probes.linkCheck(path))

        current = "portal"
        add(await Probes.portalCheck())

        current = "dns"
        add(await Probes.dnsCheck())

        current = "nxdomain"
        add(await Probes.nxdomainCheck())

        current = "doh"
        add(await Probes.dohCheck())

        current = "tls"
        add(await Probes.tlsCheck())

        current = "ipv6"
        add(await Probes.ipv6Check(vpnOn: vpnOn, expected: expected, path: path))

        current = "exit"
        add(await Probes.exitCheck(vpnOn: vpnOn, expected: expected))

        current = "quality"
        add(await Probes.qualityCheck())
    }

    private func add(_ check: Check) {
        guard !Task.isCancelled else { return }
        checks.append(check)
    }

    /// 스크린샷용: 검사 도중(레이더가 도는 중) 모습
    func showDemo(running: Bool) {
        self.running = running
        checks = running ? Array(Self.demoChecks.prefix(4)) : Self.demoChecks
        current = running ? Self.order[4] : nil
        finishedAt = running ? nil : Date().addingTimeInterval(-8)
    }

    static let demoChecks: [Check] = [
        Check(id: "link", detail: "wi-fi · ipv4+ipv6", level: .info),
        Check(id: "portal", detail: "no login page · http untouched", level: .pass),
        Check(id: "dns", detail: "one.one.one.one → 1.1.1.1 ✓", level: .pass),
        Check(id: "nxdomain", detail: "missing names answered → 175.223.10.4 (ad dns)", level: .warn),
        Check(id: "doh", detail: "encrypted dns reachable", level: .pass),
        Check(id: "tls", detail: "chain ends at a system root", level: .pass),
        Check(id: "ipv6", detail: "ipv6 available · rescan with vpn on to test leaks", level: .info),
        Check(id: "exit", detail: "211.36.1.9 · KR", level: .info),
        Check(id: "quality", detail: "kr 4ms · jitter 1ms · loss 0/6", level: .pass),
    ]
}

/// 검사 하나하나(액터 밖에서 돈다). 결과는 NetScan이 한 줄씩 쌓는다.
private enum Probes {
    typealias Check = NetScan.Check
    typealias Level = NetScan.Level

    static func linkCheck(_ path: NWPath?) -> Check {
        guard let path else { return Check(id: "link", detail: "no path info", level: .warn) }
        guard path.status == .satisfied else { return Check(id: "link", detail: "offline · no route", level: .fail) }
        var kind = "other"
        if path.usesInterfaceType(.wifi) { kind = "wi-fi" }
        else if path.usesInterfaceType(.cellular) { kind = "cellular" }
        else if path.usesInterfaceType(.wiredEthernet) { kind = "ethernet" }
        var bits = [kind]
        switch (path.supportsIPv4, path.supportsIPv6) {
        case (true, true): bits.append("ipv4+ipv6")
        case (false, true): bits.append("ipv6 only")
        default: bits.append("ipv4")
        }
        if path.isExpensive { bits.append("metered") }
        if path.isConstrained { bits.append("low data") }
        return Check(id: "link", detail: bits.joined(separator: " · "), level: .info)
    }

    static func portalCheck() async -> Check {
        guard let url = URL(string: "http://captive.apple.com/hotspot-detect.html") else {
            return Check(id: "portal", detail: "skipped", level: .info)
        }
        guard let (data, response) = try? await load(from: url) else {
            return Check(id: "portal", detail: "apple check unreachable", level: .warn)
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        if (response as? HTTPURLResponse)?.statusCode == 200, body.contains("Success") {
            return Check(id: "portal", detail: "no login page · http untouched", level: .pass)
        }
        return Check(id: "portal", detail: "login page or http rewritten in transit", level: .warn)
    }

    static func dnsCheck() async -> Check {
        guard let answers = await resolve("one.one.one.one") else {
            return Check(id: "dns", detail: "resolver didn't answer", level: .warn)
        }
        if answers.contains("1.1.1.1") || answers.contains("1.0.0.1") {
            return Check(id: "dns", detail: "one.one.one.one → 1.1.1.1 ✓", level: .pass)
        }
        return Check(id: "dns", detail: "answers rewritten → \(answers.first ?? "?")", level: .fail)
    }

    static func nxdomainCheck() async -> Check {
        let label = "nago-" + UUID().uuidString.prefix(10).lowercased()
        if let answers = await resolve("\(label).example.com"), let first = answers.first {
            return Check(id: "nxdomain", detail: "missing names answered → \(first) (ad dns)", level: .warn)
        }
        return Check(id: "nxdomain", detail: "missing names stay missing", level: .pass)
    }

    static func dohCheck() async -> Check {
        guard let url = URL(string: "https://1.1.1.1/dns-query?name=one.one.one.one&type=A") else {
            return Check(id: "doh", detail: "skipped", level: .info)
        }
        var request = URLRequest(url: url)
        request.setValue("application/dns-json", forHTTPHeaderField: "accept")
        guard let (data, response) = try? await load(request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              String(data: data, encoding: .utf8)?.contains("1.1.1.1") == true else {
            return Check(id: "doh", detail: "encrypted dns blocked · try unicorn or wg", level: .warn)
        }
        return Check(id: "doh", detail: "encrypted dns reachable", level: .pass)
    }

    static func tlsCheck() async -> Check {
        guard let url = URL(string: "https://www.apple.com/library/test/success.html") else {
            return Check(id: "tls", detail: "skipped", level: .info)
        }
        let probe = TrustProbe()
        let session = URLSession(configuration: config, delegate: probe, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let ok = (try? await session.data(from: url)) != nil
        switch probe.result {
        case .unspecified?:
            return Check(id: "tls", detail: "chain ends at a system root", level: .pass)
        case .proceed?:
            return Check(id: "tls", detail: "user-installed root trusted · traffic can be inspected", level: .warn)
        case .none where !ok:
            return Check(id: "tls", detail: "https unreachable", level: .warn)
        default:
            return Check(id: "tls", detail: "certificate rejected · interception?", level: .fail)
        }
    }

    static func ipv6Check(vpnOn: Bool, expected: VPNRegion?, path: NWPath?) async -> Check {
        guard vpnOn else {
            let v6 = path?.supportsIPv6 == true
            return Check(id: "ipv6", detail: v6 ? "ipv6 available · rescan with vpn on to test leaks" : "ipv4 only", level: .info)
        }
        guard let url = URL(string: "https://[2606:4700:4700::1111]/cdn-cgi/trace"),
              let (data, _) = try? await load(from: url),
              let text = String(data: data, encoding: .utf8) else {
            return Check(id: "ipv6", detail: "no ipv6 path around the tunnel", level: .pass)
        }
        let loc = trace(text)["loc"] ?? "?"
        if let expected, loc == expected.countryCode {
            return Check(id: "ipv6", detail: "ipv6 also exits in \(loc)", level: .pass)
        }
        return Check(id: "ipv6", detail: "ipv6 leaks outside the vpn → \(loc)", level: .fail)
    }

    static func exitCheck(vpnOn: Bool, expected: VPNRegion?) async -> Check {
        guard let info = await ExitInfo.fetch() else {
            return Check(id: "exit", detail: "trace unreachable", level: .warn)
        }
        let head = "\(info.ip) · \(info.country)"
        guard vpnOn, let expected else { return Check(id: "exit", detail: head, level: .info) }
        if info.country == expected.countryCode { return Check(id: "exit", detail: head + " ✓", level: .pass) }
        return Check(id: "exit", detail: head + " ≠ \(expected.countryCode)", level: .fail)
    }

    static func qualityCheck() async -> Check {
        let here = GeoPoint.here
        let nearest = VPNRegion.allCases.min { here.km(to: $0.geo) < here.km(to: $1.geo) } ?? .kr
        let samples = await LatencyProbe.samples(nearest, count: 6)
        let got = samples.compactMap { $0 }
        guard !got.isEmpty else {
            return Check(id: "quality", detail: "\(nearest.rawValue) unreachable", level: .fail)
        }
        let sorted = got.sorted()
        let median = sorted[sorted.count / 2]
        let jitter = zip(got, got.dropFirst()).map { abs($0 - $1) }.reduce(0, +) / Double(max(got.count - 1, 1))
        let lost = samples.count - got.count
        let level: Level = lost > 0 || jitter > 30 || median > 250 ? .warn : .pass
        return Check(id: "quality",
                     detail: String(format: "%@ %.0fms · jitter %.0fms · loss %d/%d", nearest.rawValue, median, jitter, lost, samples.count),
                     level: level)
    }

    // MARK: 도구

    static var config: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        return config
    }

    /// 검사마다 새 세션(연결을 다시 쓰지 않는다). VPN을 켜고 끄는 사이에 예전 회선에 묶인 연결을 다시 쓰면
    /// 터널 밖으로 나가서 결과가 틀린다(연결됐는데 출구가 KR로 보이는 것)
    static func load(from url: URL) async throws -> (Data, URLResponse) {
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(from: url)
    }

    static func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request)
    }

    static func trace(_ text: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
        }
        return fields
    }

    /// 지금 회선 정보(처음 한 번 오는 값)
    static func currentPath() async -> NWPath? {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let once = Once()
            monitor.pathUpdateHandler = { path in
                guard once.claim() else { return }
                monitor.cancel()
                continuation.resume(returning: path)
            }
            monitor.start(queue: DispatchQueue(label: "nago.scan.path"))
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                guard once.claim() else { return }
                monitor.cancel()
                continuation.resume(returning: nil)
            }
        }
    }

    /// 시스템 DNS로 IPv4 주소를 찾는다(4초 안에 안 오면 nil)
    static func resolve(_ host: String) async -> [String]? {
        await withCheckedContinuation { continuation in
            let once = Once()
            DispatchQueue.global().async {
                let answers = getaddrinfoV4(host)
                if once.claim() { continuation.resume(returning: answers) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 4) {
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    static func getaddrinfoV4(_ host: String) -> [String]? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(first) }
        var out: [String] = []
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let ai = node {
            if ai.pointee.ai_family == AF_INET, let sa = ai.pointee.ai_addr {
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { v4 in
                    var addr = v4.pointee.sin_addr
                    _ = inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN))
                }
                out.append(String(cString: buffer))
            }
            node = ai.pointee.ai_next
        }
        return out.isEmpty ? nil : out
    }
}

/// 한 번만 통과시키는 문(먼저 온 쪽만 continuation을 깨운다)
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// 서버 인증서를 시스템이 어떻게 믿었는지 받아 둔다.
/// `.unspecified`는 기본 루트로 이어짐, `.proceed`는 사용자가 직접 믿게 한 루트(회사·검열 장비 프록시가 흔히 이렇다).
private final class TrustProbe: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SecTrustResultType?

    var result: SecTrustResultType? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        var trustResult = SecTrustResultType.invalid
        let trusted = SecTrustEvaluateWithError(trust, nil)
        SecTrustGetTrustResult(trust, &trustResult)
        lock.lock()
        stored = trusted ? trustResult : .recoverableTrustFailure
        lock.unlock()
        completionHandler(.performDefaultHandling, nil)
    }
}
