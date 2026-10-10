import Foundation
import Network

/// DNS가 아닌 UDP를 그대로 중계한다.
///
/// 터널이 기본 경로를 가져가 버리기 때문에, 중계하지 않으면 게임이나 통화처럼
/// UDP를 쓰는 앱이 전부 멈춘다.
final class UnicornUDPFlow {

    struct Key: Hashable {
        let source: IPAddr
        let sourcePort: UInt16
        let destination: IPAddr
        let destinationPort: UInt16
    }

    let key: Key
    private(set) var lastActivity = Date()

    private let queue: DispatchQueue
    private let emit: (Data, NSNumber) -> Void
    private let onClose: (Key) -> Void
    private var connection: NWConnection?
    private var closed = false

    init(
        key: Key,
        queue: DispatchQueue,
        emit: @escaping (Data, NSNumber) -> Void,
        onClose: @escaping (Key) -> Void
    ) {
        self.key = key
        self.queue = queue
        self.emit = emit
        self.onClose = onClose
    }

    /// 흐름 표에 넣은 다음에 호출한다(연결이 바로 실패하면 onClose가 불린다).
    func start() {
        guard let host = key.destination.networkHost,
              let port = NWEndpoint.Port(rawValue: key.destinationPort)
        else {
            close()
            return
        }
        let parameters = NWParameters.udp
        parameters.prohibitedInterfaceTypes = [.other]

        let connection = NWConnection(host: host, port: port, using: parameters)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receive(connection)
            case .failed, .cancelled:
                self.close()
            default:
                break
            }
        }
        self.connection = connection
        connection.start(queue: queue)
    }

    func send(_ payload: [UInt8]) {
        lastActivity = Date()
        connection?.send(content: Data(payload), completion: .idempotent)
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.lastActivity = Date()
                let datagram = UDPDatagram(
                    sourcePort: self.key.destinationPort,
                    destinationPort: self.key.sourcePort,
                    payload: [UInt8](data)
                )
                let transport = datagram.serialized(
                    source: self.key.destination, destination: self.key.source
                )
                let packet = IPDatagram.packet(
                    source: self.key.destination, destination: self.key.source,
                    protocolNumber: IPDatagram.udp, payload: transport
                )
                self.emit(
                    packet,
                    self.key.source.isIPv6 ? NSNumber(value: AF_INET6) : NSNumber(value: AF_INET)
                )
            }
            if error != nil { return }
            self.receive(connection)
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection?.cancel()
        connection = nil
        onClose(key)
    }
}
