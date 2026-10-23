import NetworkExtension
import WireGuardKit
import os

/// NAGO VPN의 터널(앱 확장). 앱이 providerConfiguration에 넣어 준 값으로 엔진을 띄운다.
/// - mode "unicorn": 유니콘 HTTPS(SNI 차단 우회). 바깥으로 나가지 않고 기기 안에서
///   TLS 첫 패킷만 쪼개 보낸다(UnicornStack)
/// - engine "neptun": NepTUN(Rust, NordVPN 엔진). utun을 엔진이 직접 읽고 쓴다
/// - engine "go": WireGuardKit(wireguard-go, 공식 WireGuard 앱과 같은 엔진)
/// 서버가 유휴로 꺼지거나 켜지면서 IP가 바뀌면 핸드셰이크가 끊긴다. 그때 국가 API로 서버를 깨우고 새 주소로 바꾼다.
/// 상태는 메인 액터에서만 만진다(시스템 콜백, 엔진 콜백, 감시 작업이 서로 다른 스레드에서 온다).
final class PacketTunnelProvider: NEPacketTunnelProvider {
    static let log = Logger(subsystem: "nago.vpn.tunnel", category: "wg")

    private let journal = TunnelJournal()
    private lazy var adapter = WireGuardAdapter(with: self) { [journal = self.journal] level, message in
        if level == .error {
            journal.add("go: \(message)")
        } else {
            Self.log.debug("\(message, privacy: .public)")
        }
    }
    private var neptun: NeptunEngine?
    private var current: Settings?
    private var watchdog: Task<Void, Never>?
    /// 유니콘 HTTPS로 떴을 때의 스택. 패킷은 아래 큐에서만 다룬다.
    private var unicorn: UnicornStack?
    private let unicornQueue = DispatchQueue(label: "nago.vpn.unicorn", qos: .userInitiated)

    /// providerConfiguration: privateKey, address(10.9.0.x/32), serverPub, endpoint(ip:port), dns([String]), mtu, engine,
    /// region, apiKey(서버 깨우기용)
    private struct Settings {
        let privateKey: String
        let address: String         // 10.9.0.x
        var serverPub: String
        var endpoint: String        // ip:port
        let dns: [String]
        let mtu: Int
        let engine: String
        /// NepTUN 스레드 사이 대기열 묶음 수(설정 탭 queue)
        let queue: Int
        let region: String?
        let apiKey: String?

        init?(_ proto: NEVPNProtocol?) {
            guard let p = (proto as? NETunnelProviderProtocol)?.providerConfiguration,
                  let privateKey = p["privateKey"] as? String,
                  let address = (p["address"] as? String)?.components(separatedBy: "/").first,
                  let serverPub = p["serverPub"] as? String,
                  let endpoint = p["endpoint"] as? String
            else { return nil }
            self.privateKey = privateKey
            self.address = address
            self.serverPub = serverPub
            self.endpoint = endpoint
            self.dns = (p["dns"] as? [String]) ?? ["1.1.1.1"]
            self.mtu = (p["mtu"] as? Int) ?? 1420
            self.engine = (p["engine"] as? String) ?? "neptun"
            self.queue = (p["queue"] as? Int) ?? 8
            self.region = p["region"] as? String
            self.apiKey = p["apiKey"] as? String
        }

        /// IPv6도 터널로 받아서(서버엔 IPv6가 없으니 버려짐) 진짜 IP가 IPv6로 새지 않게 할 주소
        var ipv6Address: String {
            "fd09::\(address.split(separator: ".").last ?? "1")"
        }
    }

    // MARK: 시스템 콜백

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        // 앱에서 누른 연결은 source=app. 없으면 자동 연결(On Demand)이라 저장된 주소가 낡았을 수 있다.
        let onDemand = options?["source"] == nil
        Task { @MainActor in self.start(onDemand: onDemand, completionHandler: completionHandler) }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        Task { @MainActor in self.stop(reason: reason, completionHandler: completionHandler) }
    }

    /// 앱의 logs 화면이 부른다: 최근 로그 + 핸드셰이크·주고받은 양
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        Task { @MainActor in
            let summary: String
            if let unicorn = self.unicorn {
                summary = unicorn.summary
            } else {
                summary = await self.stats()?.summary ?? ""
            }
            let report: [String: Any] = ["lines": self.journal.snapshot(), "stats": summary]
            completionHandler?(try? JSONSerialization.data(withJSONObject: report))
        }
    }

    // MARK: 시작/정지

    @MainActor
    private func start(onDemand: Bool, completionHandler: @escaping (Error?) -> Void) {
        // 유니콘 HTTPS는 서버가 없어서 WireGuard 설정(키·엔드포인트)을 읽지 않는다.
        let configuration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        if configuration?["mode"] as? String == UnicornSettings.mode {
            startUnicorn(UnicornSettings.from(providerConfiguration: configuration),
                         completionHandler: completionHandler)
            return
        }
        guard let settings = Settings(protocolConfiguration) else {
            journal.add("✗ start: no configuration")
            completionHandler(NEVPNError(.configurationInvalid))
            return
        }
        current = settings
        let engineLabel = settings.engine == "go" ? "go" : "neptun q\(settings.queue)"
        journal.add("start \(engineLabel) → \(settings.endpoint)" + (onDemand ? " · on-demand" : ""))
        let done: (Error?) -> Void = { [weak self] error in
            Task { @MainActor in
                if let error {
                    self?.journal.add("✗ start: \(error.localizedDescription)")
                } else {
                    self?.startWatchdog(quick: onDemand)
                }
                completionHandler(error)
            }
        }
        if settings.engine == "go" {
            startGo(settings, completionHandler: done)
        } else {
            startNeptun(settings, completionHandler: done)
        }
    }

    @MainActor
    private func stop(reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        watchdog?.cancel()
        watchdog = nil
        journal.add("stop · reason \(reason.rawValue)")
        if let unicorn {
            self.unicorn = nil
            // 흐름 표는 스택의 큐에서만 만진다.
            unicornQueue.async { unicorn.stop() }
            completionHandler()
            return
        }
        if let neptun {
            neptun.stop()
            self.neptun = nil
            completionHandler()
        } else if current?.engine == "go" {
            adapter.stop { _ in completionHandler() }
        } else {
            completionHandler()
        }
    }

    // MARK: 유니콘 HTTPS

    /// 기기 안에서만 도는 터널을 띄우고, 들어온 패킷을 UnicornStack에 넘긴다.
    @MainActor
    private func startUnicorn(_ s: UnicornSettings, completionHandler: @escaping (Error?) -> Void) {
        journal.add("start unicorn · \(s.summary)")
        guard s.strategy != .off else {
            completionHandler(NSError(domain: "nago.unicorn", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "unicorn: split strategy is off"]))
            return
        }
        setTunnelNetworkSettings(Self.unicornNetworkSettings(s)) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.journal.add("✗ unicorn: \(error.localizedDescription)")
                    completionHandler(error)
                    return
                }
                // 스택을 만드는 것 자체는 스레드에 민감하지 않다(안쪽 상태는 전부 unicornQueue에서만 바뀐다).
                let stack = UnicornStack(
                    settings: s,
                    queue: self.unicornQueue,
                    log: { [journal = self.journal] line in journal.add(line) },
                    write: { [weak self] packets, families in
                        self?.packetFlow.writePackets(packets, withProtocols: families)
                    }
                )
                self.unicorn = stack
                self.readUnicornPackets(into: stack)
                completionHandler(nil)
            }
        }
    }

    /// tun에서 패킷을 읽어 스택에 넘기는 루프. 스택을 강하게 붙잡고 돌린다
    /// (stop() 뒤에는 스택이 알아서 아무것도 하지 않는다).
    private func readUnicornPackets(into stack: UnicornStack) {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self else { return }
            self.unicornQueue.async {
                for packet in packets { stack.handle(packet) }
            }
            self.readUnicornPackets(into: stack)
        }
    }

    /// 유니콘 HTTPS용 터널 설정.
    ///
    /// 주소는 실제로 쓰이지 않는 벤치마크 대역(198.18/15)에서 골랐다. 기본 경로는 받아 오지만
    /// 집·회사 안쪽 주소와 DoH 서버는 빼 둔다(DoH 요청이 다시 터널로 들어오면 서로를 기다리며 멈춘다).
    /// DNS 질의를 터널 안으로 받으려고 가짜 DNS 서버 주소를 알려 주고, 응답은 UnicornDoH가 만든다.
    private static func unicornNetworkSettings(_ s: UnicornSettings) -> NEPacketTunnelNetworkSettings {
        let network = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        network.mtu = 1500

        let v4 = NEIPv4Settings(addresses: [UnicornSettings.Tunnel.ipv4],
                                subnetMasks: [UnicornSettings.Tunnel.ipv4Mask])
        v4.includedRoutes = [NEIPv4Route.default()]
        var excluded: [NEIPv4Route] = [
            NEIPv4Route(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0"),
            NEIPv4Route(destinationAddress: "172.16.0.0", subnetMask: "255.240.0.0"),
            NEIPv4Route(destinationAddress: "192.168.0.0", subnetMask: "255.255.0.0"),
            NEIPv4Route(destinationAddress: "169.254.0.0", subnetMask: "255.255.0.0"),
            NEIPv4Route(destinationAddress: "127.0.0.0", subnetMask: "255.0.0.0"),
            NEIPv4Route(destinationAddress: "224.0.0.0", subnetMask: "240.0.0.0"),
            NEIPv4Route(destinationAddress: "255.255.255.255", subnetMask: "255.255.255.255"),
        ]
        for address in [s.resolverAddress, s.plainDNSAddress] where isIPv4(address) {
            excluded.append(NEIPv4Route(destinationAddress: address, subnetMask: "255.255.255.255"))
        }
        v4.excludedRoutes = excluded
        network.ipv4Settings = v4

        if s.handleIPv6 {
            let v6 = NEIPv6Settings(addresses: [UnicornSettings.Tunnel.ipv6],
                                    networkPrefixLengths: [NSNumber(value: UnicornSettings.Tunnel.ipv6Prefix)])
            v6.includedRoutes = [NEIPv6Route.default()]
            v6.excludedRoutes = [
                NEIPv6Route(destinationAddress: "fe80::", networkPrefixLength: 10),
                NEIPv6Route(destinationAddress: "ff00::", networkPrefixLength: 8),
            ]
            network.ipv6Settings = v6
        }

        var servers = [UnicornSettings.Tunnel.dnsIPv4]
        if s.handleIPv6 { servers.append(UnicornSettings.Tunnel.dnsIPv6) }
        let dns = NEDNSSettings(servers: servers)
        dns.matchDomains = [""]     // 모든 도메인
        network.dnsSettings = dns

        return network
    }

    /// 잘못 입력한 주소가 터널 설정 전체를 깨뜨리지 않게 간단히 확인한다.
    private static func isIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }

    // MARK: NepTUN

    @MainActor
    private func startNeptun(_ s: Settings, completionHandler: @escaping (Error?) -> Void) {
        // 네트워크 설정을 먼저 적용해야 utun MTU가 맞춰지고, 그 뒤에 엔진이 MTU를 읽는다.
        setTunnelNetworkSettings(Self.networkSettings(s)) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    completionHandler(error)
                    return
                }
                guard let fd = NeptunEngine.utunFileDescriptor() else {
                    completionHandler(NSError(domain: "nago.neptun", code: 2,
                                              userInfo: [NSLocalizedDescriptionKey: "neptun: utun not found"]))
                    return
                }
                let engine = NeptunEngine()
                do {
                    try engine.start(tunFD: fd, privateKey: s.privateKey, serverPub: s.serverPub, endpoint: s.endpoint,
                                     queue: s.queue)
                    self.neptun = engine
                    completionHandler(nil)
                } catch {
                    completionHandler(error)
                }
            }
        }
    }

    /// iOS에 알려 줄 터널 설정. 서버 주소는 도중에 바뀔 수 있어서 WireGuardKit처럼 127.0.0.1을 넣는다
    /// (확장 자신의 통신은 원래 터널 밖으로 나간다).
    private static func networkSettings(_ s: Settings) -> NEPacketTunnelNetworkSettings {
        let network = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let v4 = NEIPv4Settings(addresses: [s.address], subnetMasks: ["255.255.255.255"])
        v4.includedRoutes = [NEIPv4Route.default()]
        network.ipv4Settings = v4
        let v6 = NEIPv6Settings(addresses: [s.ipv6Address], networkPrefixLengths: [128])
        v6.includedRoutes = [NEIPv6Route.default()]
        network.ipv6Settings = v6
        let dns = NEDNSSettings(servers: s.dns)
        dns.matchDomains = [""]     // 모든 도메인을 이 DNS로
        network.dnsSettings = dns
        network.mtu = NSNumber(value: s.mtu)
        return network
    }

    // MARK: WireGuardKit (Go)

    @MainActor
    private func startGo(_ s: Settings, completionHandler: @escaping (Error?) -> Void) {
        guard let config = Self.goConfiguration(s) else {
            completionHandler(NEVPNError(.configurationInvalid))
            return
        }
        adapter.start(tunnelConfiguration: config) { error in
            guard let error else {
                completionHandler(nil)
                return
            }
            completionHandler(NSError(domain: "nago.wg", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "wireguard: \(error)"]))
        }
    }

    private static func goConfiguration(_ s: Settings) -> TunnelConfiguration? {
        guard let privateKey = PrivateKey(base64Key: s.privateKey),
              let serverKey = PublicKey(base64Key: s.serverPub),
              let endpoint = Endpoint(from: s.endpoint)
        else { return nil }

        var interface = InterfaceConfiguration(privateKey: privateKey)
        interface.addresses = ["\(s.address)/32", "\(s.ipv6Address)/128"].compactMap { IPAddressRange(from: $0) }
        interface.dns = s.dns.compactMap { DNSServer(from: $0) }
        interface.mtu = UInt16(s.mtu)

        var peer = PeerConfiguration(publicKey: serverKey)
        peer.endpoint = endpoint
        peer.allowedIPs = ["0.0.0.0/0", "::/0"].compactMap { IPAddressRange(from: $0) }
        peer.persistentKeepAlive = 25

        return TunnelConfiguration(name: "nago", interface: interface, peers: [peer])
    }

    // MARK: 서버 깨우기 / 주소 따라가기

    /// 핸드셰이크가 오래 없으면(서버가 꺼졌거나 IP가 바뀜) 국가 API로 서버를 켜고 주소가 바뀌었으면 피어를 바꾼다.
    /// keepalive(25초) 덕에 정상이면 2분마다 새 핸드셰이크가 생기므로 170초를 넘으면 끊긴 것으로 본다.
    @MainActor
    private func startWatchdog(quick: Bool) {
        watchdog?.cancel()
        let started = Date()
        watchdog = Task { @MainActor [weak self] in
            var lastWake = Date.distantPast
            try? await Task.sleep(for: .seconds(quick ? 4 : 20))
            while !Task.isCancelled {
                guard let self else { return }
                let handshake = await self.stats()?.handshake
                let stale = handshake.map { Date().timeIntervalSince($0) > 170 }
                    ?? (Date().timeIntervalSince(started) > 15)
                if stale, Date().timeIntervalSince(lastWake) > 60 {
                    lastWake = Date()
                    await self.wakeServer()
                }
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    @MainActor
    private func wakeServer() async {
        guard let s = current, let code = s.region, let region = VPNRegion(rawValue: code),
              let key = s.apiKey, !key.isEmpty else { return }
        journal.add("\(code): no handshake → api")
        do {
            let target = try await RegionAPI.waitUntilReady(region, key: key) { self.journal.add($0) }
            let endpoint = "\(target.address):\(target.wgPort)"
            let serverPub = target.wgPub ?? s.serverPub
            guard endpoint != s.endpoint || serverPub != s.serverPub else {
                journal.add("\(code): up · \(endpoint)")
                return
            }
            try await replacePeer(serverPub: serverPub, endpoint: endpoint)
            journal.add("\(code): endpoint → \(endpoint)")
        } catch {
            journal.add("✗ \(code): \(error.localizedDescription)")
        }
    }

    @MainActor
    private func replacePeer(serverPub: String, endpoint: String) async throws {
        guard var s = current else { return }
        s.serverPub = serverPub
        s.endpoint = endpoint
        if let neptun {
            try neptun.replacePeer(serverPub: serverPub, endpoint: endpoint)
        } else {
            guard let config = Self.goConfiguration(s) else { throw NEVPNError(.configurationInvalid) }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                adapter.update(tunnelConfiguration: config) { error in
                    if let error {
                        continuation.resume(throwing: NSError(domain: "nago.wg", code: 2,
                                                              userInfo: [NSLocalizedDescriptionKey: "wireguard: \(error)"]))
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
        current = s
    }

    // MARK: 상태

    private struct Stats {
        let handshake: Date?
        let rx: UInt64
        let tx: UInt64

        /// UAPI get=1 응답에서 마지막 핸드셰이크와 주고받은 양을 읽는다.
        init(uapi: String) {
            var handshake: Date?
            var rx: UInt64 = 0
            var tx: UInt64 = 0
            for line in uapi.split(separator: "\n") {
                let pair = line.split(separator: "=", maxSplits: 1)
                guard pair.count == 2 else { continue }
                switch pair[0] {
                case "last_handshake_time_sec":
                    if let sec = TimeInterval(pair[1]), sec > 0 { handshake = Date(timeIntervalSince1970: sec) }
                case "rx_bytes":
                    rx += UInt64(pair[1]) ?? 0
                case "tx_bytes":
                    tx += UInt64(pair[1]) ?? 0
                default:
                    break
                }
            }
            self.handshake = handshake
            self.rx = rx
            self.tx = tx
        }

        var summary: String {
            let hs = handshake.map { "hs \(Int(Date().timeIntervalSince($0)))s ago" } ?? "hs never"
            return "\(hs) · rx \(Self.bytes(rx)) · tx \(Self.bytes(tx))"
        }

        private static func bytes(_ n: UInt64) -> String {
            ByteCountFormatter.string(fromByteCount: Int64(clamping: n), countStyle: .binary)
        }
    }

    @MainActor
    private func stats() async -> Stats? {
        let text: String?
        if let neptun {
            text = neptun.runtime()
        } else if current?.engine == "go" {
            text = await withCheckedContinuation { continuation in
                adapter.getRuntimeConfiguration { continuation.resume(returning: $0) }
            }
        } else {
            text = nil
        }
        return text.map(Stats.init(uapi:))
    }
}

/// 터널 확장의 최근 로그(200줄). 앱의 logs 화면이 handleAppMessage로 가져간다.
final class TunnelJournal {
    private var lines: [String] = []
    private let lock = NSLock()
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    func add(_ text: String) {
        PacketTunnelProvider.log.info("\(text, privacy: .public)")
        lock.lock()
        defer { lock.unlock() }
        lines.append("\(stamp.string(from: Date())) \(text)")
        if lines.count > 200 {
            lines.removeFirst(lines.count - 200)
        }
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
