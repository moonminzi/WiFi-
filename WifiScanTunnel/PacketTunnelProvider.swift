import NetworkExtension
import WireGuardKit
import os

/// NAGO VPN의 WireGuard 터널(앱 확장). 앱이 providerConfiguration에 넣어 준 값으로 엔진을 띄운다.
/// - engine "neptun": NepTUN(Rust, NordVPN 엔진). utun을 엔진이 직접 읽고 쓴다
/// - engine "go": WireGuardKit(wireguard-go, 공식 WireGuard 앱과 같은 엔진)
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private static let log = Logger(subsystem: "nago.vpn.tunnel", category: "wg")

    private lazy var adapter = WireGuardAdapter(with: self) { level, message in
        if level == .error {
            Self.log.error("\(message, privacy: .public)")
        } else {
            Self.log.debug("\(message, privacy: .public)")
        }
    }
    private var neptun: NeptunEngine?

    /// providerConfiguration: privateKey, address(10.9.0.x/32), serverPub, endpoint(ip:port), dns([String]), mtu, engine
    private struct Settings {
        let privateKey: String
        let address: String         // 10.9.0.x
        let serverPub: String
        let endpoint: String        // ip:port
        let dns: [String]
        let mtu: Int
        let engine: String

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
        }

        /// IPv6도 터널로 받아서(서버엔 IPv6가 없으니 버려짐) 진짜 IP가 IPv6로 새지 않게 할 주소
        var ipv6Address: String {
            "fd09::\(address.split(separator: ".").last ?? "1")"
        }

        var endpointHost: String {
            String(endpoint[..<(endpoint.lastIndex(of: ":") ?? endpoint.endIndex)])
        }
    }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let settings = Settings(protocolConfiguration) else {
            completionHandler(NEVPNError(.configurationInvalid))
            return
        }
        if settings.engine == "go" {
            startGo(settings, completionHandler: completionHandler)
        } else {
            startNeptun(settings, completionHandler: completionHandler)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        if let neptun {
            neptun.stop()
            self.neptun = nil
            completionHandler()
            return
        }
        adapter.stop { _ in completionHandler() }
    }

    // MARK: NepTUN

    private func startNeptun(_ s: Settings, completionHandler: @escaping (Error?) -> Void) {
        let network = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: s.endpointHost)
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

        // 네트워크 설정을 먼저 적용해야 utun MTU가 맞춰지고, 그 뒤에 엔진이 MTU를 읽는다.
        setTunnelNetworkSettings(network) { [weak self] error in
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
                try engine.start(tunFD: fd, privateKey: s.privateKey, serverPub: s.serverPub, endpoint: s.endpoint)
                self.neptun = engine
                completionHandler(nil)
            } catch {
                Self.log.error("\(error.localizedDescription, privacy: .public)")
                completionHandler(error)
            }
        }
    }

    // MARK: WireGuardKit (Go)

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
            Self.log.error("start failed: \(String(describing: error), privacy: .public)")
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
}
