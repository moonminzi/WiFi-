import Foundation
import Network
import NetworkExtension
import os

/// NepTUN(NordVPN의 Rust WireGuard 엔진, BSD-3) 경로.
/// iOS가 만든 utun의 fd를 엔진에 넘기면 엔진 스레드들이 utun과 UDP를 직접 읽고 쓴다(Swift를 거치지 않음).
final class NeptunEngine {
    private static let log = Logger(subsystem: "nago.vpn.tunnel", category: "neptun")

    private var tun: OpaquePointer?
    private var monitor: NWPathMonitor?
    private var lastInterfaces: [String]?
    private let queue = DispatchQueue(label: "nago.neptun")

    /// 엔진 시작. 실패하면 이유를 던진다.
    func start(tunFD: Int32, privateKey: String, serverPub: String, endpoint: String) throws {
        let uapi = """
            set=1
            private_key=\(privateKey)
            replace_peers=true
            public_key=\(serverPub)
            endpoint=\(endpoint)
            persistent_keepalive_interval=25
            replace_allowed_ips=true
            allowed_ip=0.0.0.0/0
            allowed_ip=::/0


            """
        // 아이폰은 고성능 코어 2개 + 효율 코어 4개. 이벤트 루프를 코어 수에 맞추되 4개까지.
        let threads = UInt32(min(max(ProcessInfo.processInfo.activeProcessorCount, 2), 4))
        guard let handle = uapi.withCString({ nago_tun_start(tunFD, $0, threads) }) else {
            throw NSError(domain: "nago.neptun", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "neptun: \(Self.lastError())"])
        }
        tun = handle
        Self.log.info("started with \(threads) threads")

        // 와이파이↔셀룰러 전환 때 UDP 소켓을 새로 만들어야 끊기지 않는다(WireGuardKit의 bump sockets와 같은 일).
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in self?.pathChanged(path) }
        monitor.start(queue: queue)
        self.monitor = monitor
    }

    private func pathChanged(_ path: Network.NWPath) {
        let interfaces = path.availableInterfaces.map(\.name)
        defer { lastInterfaces = interfaces }
        guard let tun, path.status == .satisfied, let last = lastInterfaces, last != interfaces else { return }
        Self.log.info("network changed \(last, privacy: .public) → \(interfaces, privacy: .public)")
        nago_tun_network_changed(tun)
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        if let tun {
            nago_tun_stop(tun)
        }
        tun = nil
    }

    private static func lastError() -> String {
        var buf = [CChar](repeating: 0, count: 512)
        _ = nago_tun_last_error(&buf, buf.count)
        return String(cString: buf)
    }

    /// NEPacketTunnelProvider가 쓰는 utun의 fd를 찾는다(WireGuardKit, MIT와 같은 방법).
    static func utunFileDescriptor() -> Int32? {
        var info = nago_ctl_info()
        withUnsafeMutablePointer(to: &info.ctl_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: $0.pointee)) {
                _ = strcpy($0, "com.apple.net.utun_control")
            }
        }
        for fd: Int32 in 0...1024 {
            var addr = nago_sockaddr_ctl()
            var ret: Int32 = -1
            var len = socklen_t(MemoryLayout.size(ofValue: addr))
            withUnsafeMutablePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    ret = getpeername(fd, $0, &len)
                }
            }
            if ret != 0 || addr.sc_family != AF_SYSTEM {
                continue
            }
            if info.ctl_id == 0 {
                ret = ioctl(fd, NAGO_CTLIOCGINFO, &info)
                if ret != 0 {
                    continue
                }
            }
            if addr.sc_id == info.ctl_id {
                return fd
            }
        }
        return nil
    }
}
