import Foundation
import Network

extension IPAddr {
    /// Network.framework에 넘길 수 있는 형태로.
    var networkHost: NWEndpoint.Host? {
        if isIPv6 {
            return IPv6Address(Data(bytes)).map { NWEndpoint.Host.ipv6($0) }
        }
        return IPv4Address(Data(bytes)).map { NWEndpoint.Host.ipv4($0) }
    }
}

/// tun으로 들어온 TCP 연결 하나.
///
/// 단말이 보는 TCP는 우리가 여기서 끝내고(terminate), 실제 목적지로는 `NWConnection`으로
/// 새로 연결한다. 그래서 "보내기 직전"에 ClientHello를 쪼개 넣을 틈이 생긴다.
///
/// tun 인터페이스 반대쪽은 같은 기기의 TCP 스택이라 패킷이 사라지지 않는다.
/// 그래서 재전송 큐 없이 순서가 맞는 세그먼트만 받고 바로 ACK하는 정도로 충분하다.
final class UnicornTCPFlow {

    struct Key: Hashable {
        let source: IPAddr
        let sourcePort: UInt16
        let destination: IPAddr
        let destinationPort: UInt16
    }

    /// 한 번의 `send()`로 나갈 덩어리.
    private struct Chunk {
        let bytes: [UInt8]
        /// 앞 조각과 같은 TCP 패킷으로 합쳐지지 않게 조금 띄울지.
        let spaced: Bool
    }

    /// 단말에 알리는 수신 윈도의 최대값. 윈도 스케일 옵션은 주고받지 않아서 64KB가 한계.
    private static let maximumWindow = 65535
    /// 상류로 아직 못 보낸 바이트가 이만큼 쌓이면 윈도를 0으로 알려 단말을 멈춘다.
    /// 확장은 메모리 한도가 빡빡해서(넘으면 시스템이 확장을 죽인다) 이쪽을 막아 둬야 한다.
    private static let upstreamBufferLimit = 256 * 1024
    /// 조각 사이에 두는 간격. 로컬 스택이 패킷을 합치지 않을 만큼만.
    private static let spacing = DispatchTimeInterval.milliseconds(4)

    let key: Key
    private(set) var lastActivity = Date()

    private let settings: UnicornSettings
    private let queue: DispatchQueue
    private let emit: (Data, NSNumber) -> Void
    private let onClose: (Key) -> Void
    private let onFragment: (String?) -> Void

    private let maximumSegment: Int

    // 단말 쪽 TCP 상태
    private var initialSendSequence: UInt32 = 0
    private var sendNext: UInt32 = 0
    private var sendUnacked: UInt32 = 0
    private var receiveNext: UInt32 = 0
    private var clientWindow: UInt16 = 0
    private var handshakeDone = false
    private var clientFinished = false
    private var finSent = false
    private var closed = false

    // 원격 쪽
    private var upstream: NWConnection?
    private var upstreamReady = false
    private var upstreamFinished = false
    private var upstreamFinSent = false
    private var upstreamSending = false
    private var receiveSuspended = false

    private var toClient: [UInt8] = []
    private var upstreamQueue: [Chunk] = []
    private var queuedUpstream = 0
    private var lastWindow = 0
    private var halfCloseQueued = false

    // ClientHello 모으기
    private var watchingHello: Bool
    private var helloBuffer: [UInt8] = []
    private var helloTimeoutToken = 0

    init(
        key: Key,
        settings: UnicornSettings,
        queue: DispatchQueue,
        emit: @escaping (Data, NSNumber) -> Void,
        onFragment: @escaping (String?) -> Void,
        onClose: @escaping (Key) -> Void
    ) {
        self.key = key
        self.settings = settings
        self.queue = queue
        self.emit = emit
        self.onFragment = onFragment
        self.onClose = onClose
        self.maximumSegment = key.source.isIPv6 ? 1440 : 1460
        self.watchingHello =
            settings.strategy != .off && (settings.allPorts || key.destinationPort == 443)
    }

    // MARK: - 단말 → 우리

    func handle(_ segment: TCPSegment) {
        lastActivity = Date()
        guard !closed else { return }

        if segment.flags.contains(.rst) {
            teardown(sendReset: false)
            return
        }

        if segment.flags.contains(.syn), !segment.flags.contains(.ack) {
            if !handshakeDone {
                receiveNext = segment.sequence &+ 1
                clientWindow = segment.window
                initialSendSequence = UInt32.random(in: 0...UInt32.max)
                sendUnacked = initialSendSequence
                sendNext = initialSendSequence &+ 1
                handshakeDone = true
                startUpstream()
            }
            // 재전송된 SYN에도 같은 SYN/ACK로 답한다.
            emitSegment(
                flags: [.syn, .ack], sequence: initialSendSequence, payload: [],
                mss: UInt16(maximumSegment)
            )
            return
        }

        guard handshakeDone else { return }

        if segment.flags.contains(.ack),
           sequenceLessThan(sendUnacked, segment.acknowledgement),
           sequenceLessThanOrEqual(segment.acknowledgement, sendNext) {
            sendUnacked = segment.acknowledgement
        }
        clientWindow = segment.window

        if !segment.payload.isEmpty {
            if segment.sequence == receiveNext {
                receiveNext = receiveNext &+ UInt32(segment.payload.count)
                accept(segment.payload)
            }
            // 순서가 어긋난 세그먼트에는 지금 위치를 다시 알려 준다.
            emitSegment(flags: [.ack], sequence: sendNext, payload: [])
        }

        if segment.flags.contains(.fin),
           segment.sequence &+ UInt32(segment.payload.count) == receiveNext {
            receiveNext = receiveNext &+ 1
            clientFinished = true
            emitSegment(flags: [.ack], sequence: sendNext, payload: [])
            flushHello(force: true)
            halfCloseQueued = true
            pumpUpstream()
        }

        pumpToClient()
    }

    /// 단말이 보낸 데이터. ClientHello를 기다리는 중이면 모아 두고, 아니면 바로 흘린다.
    private func accept(_ payload: [UInt8]) {
        guard watchingHello else {
            enqueueUpstream(Chunk(bytes: payload, spaced: false))
            pumpUpstream()
            return
        }

        helloBuffer += payload

        // TLS 핸드셰이크가 아니면 더 볼 필요가 없다.
        if !TLSClientHello.looksLikeHandshake(helloBuffer) {
            flushHello(force: true)
            return
        }
        if let expected = TLSClientHello.expectedRecordLength(helloBuffer),
           helloBuffer.count >= expected {
            flushHello(force: false)
            return
        }
        // 레코드가 덜 왔다. 조금 기다렸다가 그대로라도 보낸다.
        guard helloBuffer.count < 20_000 else {
            flushHello(force: true)
            return
        }
        helloTimeoutToken += 1
        let token = helloTimeoutToken
        queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
            guard let self, self.helloTimeoutToken == token, self.watchingHello else { return }
            self.flushHello(force: true)
        }
    }

    /// 모아 둔 ClientHello를 쪼개서(가능하면) 보낸다.
    /// `force`가 참이면 더 기다리지 않고 지금 있는 만큼만 내보낸다.
    private func flushHello(force: Bool) {
        guard watchingHello else { return }
        watchingHello = false
        helloTimeoutToken += 1
        let buffered = helloBuffer
        helloBuffer = []
        guard !buffered.isEmpty else { return }

        let fragmenter = ClientHelloFragmenter(settings: settings)
        if let split = fragmenter.split(buffered), split.pieces.count > 1 {
            onFragment(split.hostname)
            for (index, piece) in split.pieces.enumerated() {
                enqueueUpstream(
                    Chunk(bytes: piece, spaced: index > 0 && settings.strategy.splitsSegment)
                )
            }
        } else {
            enqueueUpstream(Chunk(bytes: buffered, spaced: false))
        }
        pumpUpstream()
    }

    // MARK: - 우리 → 원격

    private func enqueueUpstream(_ chunk: Chunk) {
        upstreamQueue.append(chunk)
        queuedUpstream += chunk.bytes.count
    }

    private func startUpstream() {
        guard let host = key.destination.networkHost,
              let port = NWEndpoint.Port(rawValue: key.destinationPort)
        else {
            teardown(sendReset: true)
            return
        }

        let tcp = NWProtocolTCP.Options()
        // 쪼갠 조각이 커널에서 다시 합쳐지지 않게 Nagle을 끈다.
        tcp.noDelay = true
        tcp.connectionTimeout = 10
        let parameters = NWParameters(tls: nil, tcp: tcp)
        // 우리가 만든 터널(utun)로 되돌아가지 않도록 막는다.
        parameters.prohibitedInterfaceTypes = [.other]

        let connection = NWConnection(host: host, port: port, using: parameters)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready:
                self.upstreamReady = true
                self.receiveUpstream(connection)
                self.pumpUpstream()
            case .failed, .cancelled:
                self.teardown(sendReset: true)
            default:
                break
            }
        }
        upstream = connection
        connection.start(queue: queue)
    }

    private func pumpUpstream() {
        guard upstreamReady, !upstreamSending, !closed, let connection = upstream else { return }

        guard !upstreamQueue.isEmpty else {
            if halfCloseQueued, !upstreamFinSent {
                upstreamFinSent = true
                connection.send(content: nil, isComplete: true, completion: .idempotent)
            }
            return
        }

        let chunk = upstreamQueue.removeFirst()
        queuedUpstream -= chunk.bytes.count
        upstreamSending = true
        let send = { [weak self] in
            guard let self, !self.closed else { return }
            connection.send(
                content: Data(chunk.bytes),
                completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    self.upstreamSending = false
                    if error != nil {
                        self.teardown(sendReset: true)
                        return
                    }
                    // 윈도를 0으로 알려 둔 상태에서 자리가 생겼으면 바로 알려 준다.
                    if self.lastWindow == 0, self.currentWindow > 0, self.handshakeDone, !self.closed {
                        self.emitSegment(flags: [.ack], sequence: self.sendNext, payload: [])
                    }
                    self.pumpUpstream()
                }
            )
        }
        if chunk.spaced {
            queue.asyncAfter(deadline: .now() + Self.spacing, execute: send)
        } else {
            send()
        }
    }

    // MARK: - 원격 → 단말

    private func receiveUpstream(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32768) {
            [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            self.lastActivity = Date()

            if let data, !data.isEmpty {
                self.toClient += [UInt8](data)
                self.pumpToClient()
            }
            if isComplete || error != nil {
                self.upstreamFinished = true
                self.pumpToClient()
                return
            }
            // 단말로 보낼 대기열이 많이 쌓였으면 잠시 멈춘다(흐름 제어).
            if self.toClient.count > 128 * 1024 {
                self.receiveSuspended = true
            } else {
                self.receiveUpstream(connection)
            }
        }
    }

    private func pumpToClient() {
        while !toClient.isEmpty {
            let inFlight = Int(sendNext &- sendUnacked)
            let room = Int(clientWindow) - inFlight
            guard room > 0 else { break }
            let count = min(room, maximumSegment, toClient.count)
            emitSegment(flags: [.ack, .psh], sequence: sendNext, payload: Array(toClient[0..<count]))
            sendNext = sendNext &+ UInt32(count)
            toClient.removeFirst(count)
        }

        if receiveSuspended, toClient.count < 32 * 1024, !upstreamFinished,
           let connection = upstream {
            receiveSuspended = false
            receiveUpstream(connection)
        }

        if upstreamFinished, toClient.isEmpty, !finSent, handshakeDone {
            emitSegment(flags: [.fin, .ack], sequence: sendNext, payload: [])
            sendNext = sendNext &+ 1
            finSent = true
        }
        if clientFinished, finSent, sequenceLessThanOrEqual(sendNext, sendUnacked) {
            teardown(sendReset: false)
        }
    }

    // MARK: - 정리

    func teardown(sendReset: Bool) {
        guard !closed else { return }
        closed = true
        if sendReset, handshakeDone {
            emitSegment(flags: [.rst, .ack], sequence: sendNext, payload: [])
        }
        upstream?.cancel()
        upstream = nil
        toClient = []
        upstreamQueue = []
        helloBuffer = []
        onClose(key)
    }

    private func emitSegment(
        flags: TCPSegment.Flags, sequence: UInt32, payload: [UInt8], mss: UInt16? = nil
    ) {
        // 단말에게는 "원격이 보낸 패킷"처럼 보여야 하므로 주소/포트를 뒤집는다.
        let segment = TCPSegment(
            sourcePort: key.destinationPort,
            destinationPort: key.sourcePort,
            sequence: sequence,
            acknowledgement: receiveNext,
            flags: flags,
            window: UInt16(currentWindow),
            payload: payload,
            maximumSegmentSize: mss
        )
        lastWindow = currentWindow
        let transport = segment.serialized(source: key.destination, destination: key.source)
        let packet = IPDatagram.packet(
            source: key.destination, destination: key.source,
            protocolNumber: IPDatagram.tcp, payload: transport
        )
        emit(packet, key.source.isIPv6 ? NSNumber(value: AF_INET6) : NSNumber(value: AF_INET))
    }

    /// 지금 단말에 알릴 수신 윈도. 상류로 못 보낸 게 쌓이면 줄어든다.
    private var currentWindow: Int {
        let free = Self.upstreamBufferLimit - queuedUpstream
        return min(max(free, 0), Self.maximumWindow)
    }
}
