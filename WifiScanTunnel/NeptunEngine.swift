import Foundation
import Network
import NetworkExtension
import os

/// NepTUN(NordVPN의 Rust WireGuard 엔진, BSD-3) 경로.
/// iOS가 만든 utun의 fd를 엔진에 넘기면 엔진 스레드들이 utun과 UDP를 직접 읽고 쓴다(Swift를 거치지 않음).
final class NeptunEngine {
    private static let log = Logger(subsystem: "nago.vpn.tunnel", category: "neptun")

    private var tun: OpaquePointer?
    /// nagoing을 엔진에 바로 붙일 때(nago_nagoing_attach) 쓰는 엔진 포인터. 멈춘 뒤엔 nil.
    var rawHandle: OpaquePointer? { tun }
    private var monitor: NWPathMonitor?
    private var lastInterfaces: [String]?
    private let queue = DispatchQueue(label: "nago.neptun")
    /// 터널 로그(앱 logs 화면)에 남길 한 줄
    var journal: ((String) -> Void)?

    /// wireguard-go와 같은 UDP 소켓 버퍼(받기·보내기)
    private static let socketBuffer: Int32 = 7 << 20

    /// 서버(피어) 하나짜리 UAPI 설정. privateKey가 없으면 피어만 바꾼다.
    private static func uapi(privateKey: String?, serverPub: String, endpoint: String) -> String {
        var lines = ["set=1"]
        if let privateKey { lines.append("private_key=\(privateKey)") }
        lines += [
            "replace_peers=true",
            "public_key=\(serverPub)",
            "endpoint=\(endpoint)",
            "persistent_keepalive_interval=25",
            "replace_allowed_ips=true",
            "allowed_ip=0.0.0.0/0",
            "allowed_ip=::/0",
        ]
        return lines.joined(separator: "\n") + "\n\n"
    }

    /// 엔진 시작. 실패하면 이유를 던진다.
    /// - loops: 이벤트 루프 수(1~4, 기본 1). 애플에선 엔진이 패킷을 이벤트 루프에서 바로 처리한다
    ///   (작업 스레드·스레드 사이 대기열이 없다). 2개면 내려받기와 올리기·ACK가 다른 코어에서 겹치지만,
    ///   폰 속도에서는 패킷마다 다른 코어를 깨우고 피어 잠금을 다투는 비용이 더 커서 1개가 같은 속도에
    ///   CPU를 25~32% 덜 쓴다(tools/nagotun-bench, 코어 2개에 묶어서 잼)
    func start(tunFD: Int32, privateKey: String, serverPub: String, endpoint: String, loops: Int) throws {
        let uapi = Self.uapi(privateKey: privateKey, serverPub: serverPub, endpoint: endpoint)
        let threads = UInt32(min(max(loops, 1), 4))
        // 마지막 인자(스레드 사이 대기열)는 애플에서 쓰이지 않는다
        guard let handle = uapi.withCString({ nago_tun_start(tunFD, $0, threads, 0) }) else {
            throw NSError(domain: "nago.neptun", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "NagoTun: \(Self.lastError())"])
        }
        tun = handle
        Self.log.info("started with \(threads) loops")
        // UDP 소켓은 엔진을 만들 때 열린다(open_listen_socket). 바로 키운다
        tuneSockets(reason: "start")

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
        // 엔진이 소켓을 다시 만들었을 수 있어서 한 번 더(이미 큰 소켓은 그대로)
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.tuneSockets(reason: "network") }
    }

    // MARK: UDP 소켓 버퍼

    /// NepTUN은 애플에서 UDP 소켓 버퍼를 건드리지 않는다(skt_buffer_size는 애플 밖에서만 쓰임).
    /// 기본 크기면 내려받기가 몰리거나 이벤트 루프가 잠깐 비켜 있을 때 커널이 패킷을 버리고 TCP가 속도를 줄인다.
    /// 엔진 소켓을 바깥에서 받을 길이 없어서 utun을 찾을 때처럼 fd를 훑어, 이 확장의 IPv4/IPv6 UDP 소켓을 키운다
    /// (utun은 AF_SYSTEM이라 빠진다). 실제로 잡힌 크기를 로그에 남긴다.
    private func tuneSockets(reason: String) {
        var tuned: [String] = []
        for fd: Int32 in 0...1024 where Self.isInternetUDP(fd) {
            let rcv = Self.grow(fd, SO_RCVBUF)
            let snd = Self.grow(fd, SO_SNDBUF)
            tuned.append("fd\(fd) rcv \(rcv >> 10)K snd \(snd >> 10)K")
        }
        let line = "udp buffers (\(reason)): " + (tuned.isEmpty ? "no sockets" : tuned.joined(separator: ", "))
        Self.log.info("\(line, privacy: .public)")
        journal?(line)
    }

    private static func isInternetUDP(_ fd: Int32) -> Bool {
        var type: Int32 = 0
        var typeLength = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &typeLength) == 0, type == SOCK_DGRAM else { return false }
        var address = sockaddr_storage()
        var addressLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &addressLength) }
        }
        let family = Int32(address.ss_family)
        return named == 0 && (family == AF_INET || family == AF_INET6)
    }

    /// 7MB부터 되는 데까지(시스템 상한에 걸리면 반씩 줄여 가며) 키우고, 실제로 잡힌 크기를 돌려준다.
    /// 이미 그보다 크면 건드리지 않는다.
    private static func grow(_ fd: Int32, _ option: Int32) -> Int32 {
        let length = socklen_t(MemoryLayout<Int32>.size)
        var current: Int32 = 0
        var currentLength = length
        _ = getsockopt(fd, SOL_SOCKET, option, &current, &currentLength)
        var size = socketBuffer
        while size > current, size >= 256 << 10 {
            if setsockopt(fd, SOL_SOCKET, option, &size, length) == 0 { break }
            size /= 2
        }
        var actual: Int32 = 0
        var actualLength = length
        _ = getsockopt(fd, SOL_SOCKET, option, &actual, &actualLength)
        return actual
    }

    func stop() {
        // 네트워크 전환 처리(queue)와 겹치면 해제된 엔진을 건드릴 수 있어서 같은 큐에서 멈춘다.
        queue.sync {
            monitor?.cancel()
            monitor = nil
            if let tun {
                nago_tun_stop(tun)
            }
            tun = nil
        }
    }

    /// 서버 주소(또는 키)가 바뀌었을 때 피어를 새로 넣는다. 새 핸드셰이크부터 다시 한다.
    func replacePeer(serverPub: String, endpoint: String) throws {
        try queue.sync {
            guard let tun else { throw NSError(domain: "nago.neptun", code: 3,
                                               userInfo: [NSLocalizedDescriptionKey: "NagoTun: not running"]) }
            let rc = Self.uapi(privateKey: nil, serverPub: serverPub, endpoint: endpoint)
                .withCString { nago_tun_set(tun, $0) }
            if rc != 0 {
                throw NSError(domain: "nago.neptun", code: Int(rc),
                              userInfo: [NSLocalizedDescriptionKey: "NagoTun: uapi set errno \(rc)"])
            }
        }
    }

    /// UAPI get=1 응답(last_handshake_time_sec, rx_bytes, tx_bytes …)
    func runtime() -> String? {
        queue.sync {
            guard let tun else { return nil }
            var buf = [CChar](repeating: 0, count: 4096)
            _ = nago_tun_get(tun, &buf, buf.count)
            return String(cString: buf)
        }
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
