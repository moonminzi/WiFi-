import Foundation
import Network
import Security

/// 유니콘 HTTPS의 DNS. 질의를 HTTPS(DoH, RFC 8484)로 보낸다.
///
/// SNI 차단은 보통 DNS 변조와 같이 온다. 평문 UDP로 묻지 않고 공개 리졸버에
/// HTTPS로 물어보면 응답이 바뀌는 걸 막을 수 있다. 받은 질의 바이트를 손대지 않고
/// 넘기고, 돌아온 바이트를 그대로 단말에 돌려준다.
///
/// 막혀 있으면(두 번 실패) 평문 DNS로 떨어진다. 인터넷이 아예 안 되는 것보다는 낫다.
final class UnicornDoH {

    private struct Request {
        let query: [UInt8]
        let completion: ([UInt8]?) -> Void
        var attempts: Int
    }

    private let settings: UnicornSettings
    private let queue: DispatchQueue

    private var connection: NWConnection?
    private var waiting: [Request] = []
    private var current: Request?
    private var buffer = Data()
    private var timeoutToken = 0

    /// DoH가 실패할 때마다 불린다(통계·로그용)
    var onFailure: ((String) -> Void)?

    init(settings: UnicornSettings, queue: DispatchQueue) {
        self.settings = settings
        self.queue = queue
    }

    func stop() {
        connection?.cancel()
        connection = nil
        let dropped = waiting
        waiting = []
        let inFlight = current
        current = nil
        for request in dropped { request.completion(nil) }
        inFlight?.completion(nil)
    }

    /// DNS 질의 하나를 해결한다. 실패하면 nil.
    func resolve(_ query: [UInt8], completion: @escaping ([UInt8]?) -> Void) {
        guard settings.resolver != .off else {
            resolvePlain(query, completion: completion)
            return
        }
        waiting.append(Request(query: query, completion: completion, attempts: 0))
        pump()
    }

    // MARK: - HTTPS

    private func pump() {
        guard current == nil, !waiting.isEmpty else { return }
        var request = waiting.removeFirst()
        request.attempts += 1
        current = request
        buffer.removeAll(keepingCapacity: true)

        let connection = ensureConnection()
        connection.send(
            content: Data(httpRequest(for: request.query)),
            completion: .contentProcessed { [weak self] error in
                guard let self, error != nil else { return }
                self.failCurrent("send")
            }
        )
        armTimeout()
    }

    private func httpRequest(for query: [UInt8]) -> [UInt8] {
        let lines = [
            "POST \(settings.resolver.path) HTTP/1.1",
            "Host: \(settings.resolverHost)",
            "Accept: application/dns-message",
            "Content-Type: application/dns-message",
            "Content-Length: \(query.count)",
            "Connection: keep-alive",
            "",
            "",
        ]
        return Array(lines.joined(separator: "\r\n").utf8) + query
    }

    private func ensureConnection() -> NWConnection {
        if let existing = connection {
            switch existing.state {
            case .failed, .cancelled:
                existing.cancel()
                connection = nil
            default:
                return existing
            }
        }

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, settings.resolverHost)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5

        let parameters = NWParameters(tls: tls, tcp: tcp)
        // 우리가 만든 터널(utun)을 다시 타지 않도록 막는다. 이걸 빼면 서로를 기다리며 멈춘다.
        parameters.prohibitedInterfaceTypes = [.other]

        let created = NWConnection(
            host: NWEndpoint.Host(settings.resolverAddress), port: 443, using: parameters
        )
        created.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed(let error) = state { self.failCurrent("tls: \(error)") }
        }
        created.start(queue: queue)
        connection = created
        receive(on: created)
        return created
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.consumeBuffer()
            }
            if error != nil || isComplete {
                if self.connection === connection { self.connection = nil }
                connection.cancel()
                if self.current != nil { self.failCurrent("closed") }
                return
            }
            self.receive(on: connection)
        }
    }

    /// HTTP/1.1 응답 하나를 꺼낸다. DoH 응답에는 Content-Length가 붙어 오는 게 표준이다.
    private func consumeBuffer() {
        guard current != nil else { return }
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }

        guard let header = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            failCurrent("header")
            return
        }
        let lines = header.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard let statusLine = lines.first, statusLine.contains(" 200") else {
            failCurrent("http \(lines.first ?? "?")")
            return
        }
        guard let lengthLine = lines.first(where: { $0.lowercased().hasPrefix("content-length:") }),
              let length = Int(lengthLine.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
        else {
            // 길이를 모르면(chunked 등) 이 연결은 버리고 다시 시도한다.
            failCurrent("no length")
            return
        }

        let bodyStart = headerEnd.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return }
        let bodyEnd = buffer.index(bodyStart, offsetBy: length)
        let body = [UInt8](buffer[bodyStart..<bodyEnd])
        buffer.removeSubrange(buffer.startIndex..<bodyEnd)

        timeoutToken += 1
        let request = current
        current = nil
        request?.completion(body)
        pump()
    }

    private func armTimeout() {
        timeoutToken += 1
        let token = timeoutToken
        queue.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.timeoutToken == token, self.current != nil else { return }
            self.failCurrent("timeout")
        }
    }

    /// 지금 처리 중인 질의를 실패 처리한다. 한 번은 연결을 새로 맺어 다시 시도하고,
    /// 그래도 안 되면 평문 DNS로 떨어진다.
    private func failCurrent(_ reason: String) {
        guard let request = current else { return }
        current = nil
        timeoutToken += 1
        onFailure?(reason)

        connection?.cancel()
        connection = nil
        buffer.removeAll(keepingCapacity: true)

        if request.attempts < 2 {
            waiting.insert(request, at: 0)
            pump()
            return
        }
        resolvePlain(request.query, completion: request.completion)
        pump()
    }

    // MARK: - 평문 DNS

    /// DoH가 막혀 있을 때 쓰는 UDP 53 경로. 변조는 막지 못한다.
    private func resolvePlain(_ query: [UInt8], completion: @escaping ([UInt8]?) -> Void) {
        let parameters = NWParameters.udp
        parameters.prohibitedInterfaceTypes = [.other]
        let connection = NWConnection(
            host: NWEndpoint.Host(settings.plainDNSAddress), port: 53, using: parameters
        )
        var finished = false
        let finish: ([UInt8]?) -> Void = { answer in
            guard !finished else { return }
            finished = true
            connection.cancel()
            completion(answer)
        }

        connection.start(queue: queue)
        connection.send(content: Data(query), completion: .contentProcessed { error in
            if error != nil { finish(nil) }
        })
        connection.receiveMessage { data, _, _, _ in
            guard let data, !data.isEmpty else {
                finish(nil)
                return
            }
            finish([UInt8](data))
        }
        queue.asyncAfter(deadline: .now() + 4) { finish(nil) }
    }
}
