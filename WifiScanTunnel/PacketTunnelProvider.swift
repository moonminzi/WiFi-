import NetworkExtension
import WireGuardKit
import os

/// NAGO VPN의 WireGuard 터널(앱 확장). 앱이 providerConfiguration에 넣어 준 값으로
/// WireGuardKit(wireguard-go)을 띄운다. 키·주소는 앱이 서버 피어 목록에 등록해 받은 것이다.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private static let log = Logger(subsystem: "nago.vpn.tunnel", category: "wg")

    private lazy var adapter = WireGuardAdapter(with: self) { level, message in
        if level == .error {
            Self.log.error("\(message, privacy: .public)")
        } else {
            Self.log.debug("\(message, privacy: .public)")
        }
    }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let config = Self.configuration(from: protocolConfiguration) else {
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

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        adapter.stop { _ in completionHandler() }
    }

    /// providerConfiguration: privateKey, address(10.9.0.x/32), serverPub, endpoint(ip:port), dns([String]), mtu
    static func configuration(from proto: NEVPNProtocol?) -> TunnelConfiguration? {
        guard let p = (proto as? NETunnelProviderProtocol)?.providerConfiguration,
              let privateKey = (p["privateKey"] as? String).flatMap({ PrivateKey(base64Key: $0) }),
              let serverKey = (p["serverPub"] as? String).flatMap({ PublicKey(base64Key: $0) }),
              let address = (p["address"] as? String).flatMap({ IPAddressRange(from: $0) }),
              let endpoint = (p["endpoint"] as? String).flatMap({ Endpoint(from: $0) })
        else { return nil }

        var interface = InterfaceConfiguration(privateKey: privateKey)
        interface.addresses = [address]
        interface.dns = ((p["dns"] as? [String]) ?? ["1.1.1.1"]).compactMap { DNSServer(from: $0) }
        interface.mtu = UInt16((p["mtu"] as? Int) ?? 1420)

        var peer = PeerConfiguration(publicKey: serverKey)
        peer.endpoint = endpoint
        // IPv6도 터널로 보내서(서버엔 IPv6가 없으니 막힘) 진짜 IP가 IPv6로 새지 않게 한다.
        peer.allowedIPs = ["0.0.0.0/0", "::/0"].compactMap { IPAddressRange(from: $0) }
        peer.persistentKeepAlive = 25

        return TunnelConfiguration(name: "nago", interface: interface, peers: [peer])
    }
}
