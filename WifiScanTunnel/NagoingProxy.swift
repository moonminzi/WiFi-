import Foundation
import Network
import os

/// nagoing 클라이언트 프록시(NagoTun의 Rust FFI 래퍼).
///
/// NepTUN은 WG 패킷을 로컬 포트(127.0.0.1:localPort)로 보내고, 이 프록시가 받아 난독화·FEC해
/// 서버(443)로 날라 준다. WireGuard는 로컬 소켓만 보므로 하나도 바뀌지 않는다.
/// 설계: 저장소 루트 `NAGOING.md`.
final class NagoingProxy {
    private static let log = Logger(subsystem: "nago.vpn.tunnel", category: "nagoing")

    /// Rust 클라이언트 포인터. 잠금은 포인터를 읽고 바꾸는 짧은 동안만 쥔다 — 멈추는 동안(Rust join)
    /// stats()·networkChanged()가 기다리지 않게, 멈출 땐 포인터를 먼저 꺼내 비워 두고 잠금 밖에서 멈춘다.
    private let lock = NSLock()
    private var client: OpaquePointer?
    private var monitor: NWPathMonitor?
    private var lastInterfaces: [String]?
    private let queue = DispatchQueue(label: "nago.nagoing")

    /// 프록시 시작. 실패하면 이유를 던진다.
    func start(psk: String, serverIP: String, udpPort: UInt16, tcpPort: UInt16, localPort: UInt16,
               settings: NagoingSettings) throws {
        let handle = psk.withCString { p in
            serverIP.withCString { ip in
                "127.0.0.1".withCString { local in
                    settings.sni.withCString { sni in
                        nago_nagoing_client_start(p, ip, udpPort, tcpPort, local, localPort,
                                                  UInt8(clamping: settings.fecK),
                                                  UInt16(clamping: settings.fecGroups),
                                                  settings.fecEnabled ? 1 : 0,
                                                  settings.prefer.code, sni)
                    }
                }
            }
        }
        guard let handle else {
            throw NSError(domain: "nago.nagoing", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "nagoing: \(Self.lastError())"])
        }
        withClient { $0 = handle }
        Self.log.info("started → \(serverIP, privacy: .public):\(udpPort)/\(tcpPort) local \(localPort)")

        // 와이파이↔셀룰러 전환 때 전송을 빠르게 다시 세운다(NeptunEngine과 같은 방식).
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in self?.pathChanged(path) }
        monitor.start(queue: queue)
        self.monitor = monitor
    }

    private func withClient<T>(_ body: (inout OpaquePointer?) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&client)
    }

    private func pathChanged(_ path: Network.NWPath) {
        let interfaces = path.availableInterfaces.map(\.name)
        defer { lastInterfaces = interfaces }
        guard path.status == .satisfied, let last = lastInterfaces, last != interfaces else { return }
        Self.log.info("network changed \(last, privacy: .public) → \(interfaces, privacy: .public)")
        networkChanged()
    }

    /// 경로가 바뀌었다고 알려 전송을 다시 세운다(watchdog/NWPathMonitor에서 호출). 바로 돌아온다.
    func networkChanged() {
        withClient { client in
            if let client {
                nago_nagoing_network_changed(client)
            }
        }
    }

    /// 상태 한 줄("udp · tx .. · rx .. · fec+..").
    func stats() -> String? {
        let text: String? = withClient { client in
            guard let client else { return nil }
            var buf = [CChar](repeating: 0, count: 256)
            _ = nago_nagoing_stats(client, &buf, buf.count)
            return String(cString: buf)
        }
        return text?.isEmpty == false ? text : nil
    }

    /// 멈추고 로컬 포트를 놓는다. Rust 쪽 join(연결 수립 중이면 최대 몇 초)을 백그라운드에서 기다리므로
    /// 메인 액터(stopTunnel·watchdog·앱 메시지 처리)를 막지 않는다. 끝나면 같은 포트로 다시 start할 수 있다.
    func shutdown() async {
        monitor?.cancel()
        monitor = nil
        let taken: OpaquePointer? = withClient { client in
            let old = client
            client = nil
            return old
        }
        guard let client = taken else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                nago_nagoing_client_stop(client)
                done.resume()
            }
        }
    }

    /// 마지막 실패 이유(NagoTun 전역 버퍼 — nago_tun과 같은 곳에 쓰인다).
    private static func lastError() -> String {
        var buf = [CChar](repeating: 0, count: 512)
        _ = nago_tun_last_error(&buf, buf.count)
        return String(cString: buf)
    }
}
