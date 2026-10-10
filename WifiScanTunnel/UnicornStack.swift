import Foundation
import Network

/// 유니콘 HTTPS 스택.
///
/// 바깥으로 나가는 터널이 아니다. tun으로 들어온 패킷을 기기 안에서 받아
/// TCP는 여기서 끝내고 실제 목적지로 다시 연결하면서, TLS 첫 패킷(ClientHello)에
/// 평문으로 들어 있는 도메인 이름(SNI)만 쪼개 보낸다. 그래서 트래픽은 서버를
/// 거치지 않고 평소 회선으로 바로 나간다.
///
/// 모든 일은 하나의 직렬 큐에서만 벌어진다(NWConnection 콜백도 같은 큐로 받는다).
/// 그래서 흐름 표에 락이 필요 없다. 숫자만 앱이 다른 스레드에서 읽어 가므로 락을 쓴다.
final class UnicornStack {

    /// DNS 응답이 UDP 한 개에 들어갈 수 있는 최대 크기(MTU 1500 - IPv6 40 - UDP 8)
    private static let maximumDNSResponse = 1452

    private let settings: UnicornSettings
    private let queue: DispatchQueue
    private let write: ([Data], [NSNumber]) -> Void
    private let log: (String) -> Void
    private let resolver: UnicornDoH
    private let counters = Counters()

    private var tcpFlows: [UnicornTCPFlow.Key: UnicornTCPFlow] = [:]
    private var udpFlows: [UnicornUDPFlow.Key: UnicornUDPFlow] = [:]
    private var reaper: DispatchSourceTimer?
    private var loggedHostnames = 0
    private var stopped = false
    private var lastFailureLog = Date.distantPast

    /// 앱의 logs 화면에 보여 줄 한 줄
    var summary: String { counters.summary }

    init(
        settings: UnicornSettings,
        queue: DispatchQueue,
        log: @escaping (String) -> Void,
        write: @escaping ([Data], [NSNumber]) -> Void
    ) {
        self.settings = settings
        self.queue = queue
        self.log = log
        self.write = write
        self.resolver = UnicornDoH(settings: settings, queue: queue)
        self.resolver.onFailure = { [weak self] reason in self?.noteDoHFailure(reason) }
        startReaper()
    }

    // MARK: - 들어온 패킷

    func handle(_ packet: Data) {
        guard !stopped, let datagram = IPDatagram.parse(packet) else { return }
        if datagram.isIPv6 && !settings.handleIPv6 { return }

        switch datagram.protocolNumber {
        case IPDatagram.tcp:
            guard let segment = TCPSegment.parse(datagram.payload) else { return }
            handleTCP(datagram, segment)
        case IPDatagram.udp:
            guard let udp = UDPDatagram.parse(datagram.payload) else { return }
            handleUDP(datagram, udp)
        default:
            break       // ICMP 등은 다루지 않는다
        }
    }

    private func handleTCP(_ datagram: IPDatagram, _ segment: TCPSegment) {
        let key = UnicornTCPFlow.Key(
            source: datagram.source,
            sourcePort: segment.sourcePort,
            destination: datagram.destination,
            destinationPort: segment.destinationPort
        )

        if let flow = tcpFlows[key] {
            flow.handle(segment)
            return
        }
        // 모르는 흐름인데 SYN이 아니면(끊긴 연결의 잔여 패킷) RST로 정리해 준다.
        guard segment.flags.contains(.syn), !segment.flags.contains(.ack) else {
            if !segment.flags.contains(.rst) { sendReset(for: datagram, segment) }
            return
        }

        let flow = UnicornTCPFlow(
            key: key,
            settings: settings,
            queue: queue,
            emit: { [weak self] packet, family in self?.write([packet], [family]) },
            onFragment: { [weak self] hostname in self?.noteSplit(hostname) },
            onClose: { [weak self] key in
                self?.tcpFlows.removeValue(forKey: key)
                self?.updateOpenCount()
            }
        )
        tcpFlows[key] = flow
        counters.addTCP()
        updateOpenCount()
        flow.handle(segment)
    }

    private func handleUDP(_ datagram: IPDatagram, _ udp: UDPDatagram) {
        // QUIC(UDP 443)은 암호가 달라 같은 수법을 쓸 수 없다. 버리면 앱이 TLS over TCP로
        // 내려오고, 그때 ClientHello를 쪼갤 수 있다.
        if settings.blockQUIC, udp.destinationPort == 443 {
            counters.addQUIC()
            return
        }

        if udp.destinationPort == 53 {
            counters.addDNS()
            resolver.resolve(udp.payload) { [weak self] answer in
                guard let self, let answer, answer.count <= Self.maximumDNSResponse else { return }
                self.sendUDP(to: datagram, udp: udp, payload: answer)
            }
            return
        }

        let key = UnicornUDPFlow.Key(
            source: datagram.source,
            sourcePort: udp.sourcePort,
            destination: datagram.destination,
            destinationPort: udp.destinationPort
        )
        if let existing = udpFlows[key] {
            existing.send(udp.payload)
            return
        }
        let flow = UnicornUDPFlow(
            key: key,
            queue: queue,
            emit: { [weak self] packet, family in self?.write([packet], [family]) },
            onClose: { [weak self] key in
                self?.udpFlows.removeValue(forKey: key)
                self?.updateOpenCount()
            }
        )
        udpFlows[key] = flow
        updateOpenCount()
        flow.start()
        flow.send(udp.payload)
    }

    // MARK: - 돌려보내기

    private func sendUDP(to datagram: IPDatagram, udp: UDPDatagram, payload: [UInt8]) {
        let reply = UDPDatagram(
            sourcePort: udp.destinationPort,
            destinationPort: udp.sourcePort,
            payload: payload
        )
        let transport = reply.serialized(source: datagram.destination, destination: datagram.source)
        let packet = IPDatagram.packet(
            source: datagram.destination, destination: datagram.source,
            protocolNumber: IPDatagram.udp, payload: transport
        )
        write([packet], [datagram.addressFamily])
    }

    private func sendReset(for datagram: IPDatagram, _ segment: TCPSegment) {
        let reset = TCPSegment(
            sourcePort: segment.destinationPort,
            destinationPort: segment.sourcePort,
            sequence: segment.acknowledgement,
            acknowledgement: segment.sequence &+ UInt32(segment.payload.count),
            flags: [.rst, .ack],
            window: 0,
            payload: [],
            maximumSegmentSize: nil
        )
        let transport = reset.serialized(source: datagram.destination, destination: datagram.source)
        let packet = IPDatagram.packet(
            source: datagram.destination, destination: datagram.source,
            protocolNumber: IPDatagram.tcp, payload: transport
        )
        write([packet], [datagram.addressFamily])
    }

    // MARK: - 숫자와 로그

    private func noteSplit(_ hostname: String?) {
        counters.addSplit()
        // 처음 몇 개만 로그에 남긴다(로그는 200줄이라 다 넣으면 시작 줄이 밀려 나간다).
        guard loggedHostnames < 5 else { return }
        loggedHostnames += 1
        log("split → \(hostname ?? "(no sni)")")
    }

    private func noteDoHFailure(_ reason: String) {
        counters.addDoHFailure()
        guard Date().timeIntervalSince(lastFailureLog) > 30 else { return }
        lastFailureLog = Date()
        log("✗ doh: \(reason) → plain dns")
    }

    private func updateOpenCount() {
        counters.setOpen(tcpFlows.count + udpFlows.count)
    }

    // MARK: - 뒷정리

    /// 오래 조용한 흐름을 치운다. FIN이 끝까지 오지 않는 연결이 쌓이는 걸 막는다.
    private func startReaper() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date()
            for flow in Array(self.tcpFlows.values)
            where now.timeIntervalSince(flow.lastActivity) > 300 {
                flow.teardown(sendReset: true)
            }
            for flow in Array(self.udpFlows.values)
            where now.timeIntervalSince(flow.lastActivity) > 60 {
                flow.close()
            }
        }
        timer.resume()
        reaper = timer
    }

    func stop() {
        stopped = true
        reaper?.cancel()
        reaper = nil
        for flow in Array(tcpFlows.values) { flow.teardown(sendReset: false) }
        for flow in Array(udpFlows.values) { flow.close() }
        tcpFlows = [:]
        udpFlows = [:]
        resolver.stop()
        updateOpenCount()
    }

    /// 앱이 다른 스레드에서 읽어 가는 숫자들
    private final class Counters {
        private let lock = NSLock()
        private var split = 0
        private var dns = 0
        private var dohFailures = 0
        private var quic = 0
        private var tcp = 0
        private var open = 0

        func addSplit() { bump { $0.split += 1 } }
        func addDNS() { bump { $0.dns += 1 } }
        func addDoHFailure() { bump { $0.dohFailures += 1 } }
        func addQUIC() { bump { $0.quic += 1 } }
        func addTCP() { bump { $0.tcp += 1 } }
        func setOpen(_ count: Int) { bump { $0.open = count } }

        private func bump(_ change: (Counters) -> Void) {
            lock.lock()
            change(self)
            lock.unlock()
        }

        var summary: String {
            lock.lock()
            defer { lock.unlock() }
            var parts = ["split \(split)", "tcp \(tcp)", "open \(open)", "dns \(dns)"]
            if dohFailures > 0 { parts.append("doh ✗\(dohFailures)") }
            if quic > 0 { parts.append("quic ✗\(quic)") }
            return parts.joined(separator: " · ")
        }
    }
}
