import Foundation
import Network
import Security

/// 유니콘 HTTPS의 DNS. 질의를 HTTPS(DoH, RFC 8484)로 보낸다.
///
/// SNI 차단은 보통 DNS 변조와 같이 온다. 평문 UDP로 묻지 않고 공개 리졸버에
/// HTTPS로 물어보면 응답이 바뀌는 걸 막을 수 있다. 받은 질의 바이트를 손대지 않고
/// 넘기고, 돌아온 바이트를 그대로 단말에 돌려준다.
///
/// HTTP/1.1은 한 연결에서 한 번에 한 질의씩만 안전하게 주고받을 수 있다(파이프라이닝은
/// 서버에 따라 끊긴다). 페이지 하나 열 때 DNS가 10~20개 나가므로 연결을 여러 개 두고
/// 동시에 처리한다. 막혀 있으면(두 번 실패) 평문 DNS로 떨어진다.
///
/// 모든 일은 호출한 쪽의 직렬 큐에서만 벌어져서 락이 필요 없다.
final class UnicornDoH {

    /// 동시에 열어 둘 연결 수
    private static let channelCount = 4
    /// 질의 하나를 기다리는 시간
    private static let timeout: TimeInterval = 4

    private struct Request {
        let query: [UInt8]
        let completion: ([UInt8]?) -> Void
        var attempts: Int
    }

    /// 연결 하나와 그 위에서 처리 중인 질의.
    private final class Channel {
        var connection: NWConnection?
        var request: Request?
        var buffer = Data()
        var timeoutToken = 0

        var isIdle: Bool { request == nil }
    }

    private let settings: UnicornSettings
    private let queue: DispatchQueue
    private var channels: [Channel] = []
    private var waiting: [Request] = []
    private var stopped = false

    /// DoH가 실패할 때마다 불린다(통계·로그용)
    var onFailure: ((String) -> Void)?

    init(settings: UnicornSettings, queue: DispatchQueue) {
        self.settings = settings
        self.queue = queue
    }

    func stop() {
        stopped = true
        let dropped = waiting
        waiting = []
        for channel in channels {
            channel.timeoutToken += 1
            channel.connection?.cancel()
            channel.connection = nil
            let request = channel.request
            channel.request = nil
            request?.completion(nil)
        }
        channels = []
        for request in dropped { request.completion(nil) }
    }

    /// DNS 질의 하나를 해결한다. 실패하면 nil.
    func resolve(_ query: [UInt8], completion: @escaping ([UInt8]?) -> Void) {
        guard !stopped else {
            completion(nil)
            return
        }
        guard settings.resolver != .off else {
            resolvePlain(query, completion: completion)
            return
        }
        waiting.append(Request(query: query, completion: completion, attempts: 0))
        pump()
    }

    // MARK: - HTTPS

    /// 기다리는 질의를 빈 연결에 하나씩 얹는다.
    private func pump() {
        while !stopped, !waiting.isEmpty, let channel = availableChannel() {
            var request = waiting.removeFirst()
            request.attempts += 1
            send(request, on: channel)
        }
    }

    /// 비어 있는 연결, 없으면 새로 만들 자리, 그것도 없으면 nil.
    private func availableChannel() -> Channel? {
        if let idle = channels.first(where: { $0.isIdle }) { return idle }
        guard channels.count < Self.channelCount else { return nil }
        let channel = Channel()
        channels.append(channel)
        return channel
    }

    private func send(_ request: Request, on channel: Channel) {
        channel.request = request
        channel.buffer.removeAll(keepingCapacity: true)

        let connection = connection(for: channel)
        connection.send(
            content: Data(httpRequest(for: request.query)),
            completion: .contentProcessed { [weak self] error in
                guard let self, error != nil else { return }
                self.fail(channel, "send")
            }
        )
        armTimeout(channel)
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

    private func connection(for channel: Channel) -> NWConnection {
        if let existing = channel.connection {
            switch existing.state {
            case .failed, .cancelled:
                existing.cancel()
                channel.connection = nil
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
            if case .failed(let error) = state { self.fail(channel, "tls: \(error)") }
        }
        channel.connection = created
        created.start(queue: queue)
        receive(on: channel, connection: created)
        return created
    }

    private func receive(on channel: Channel, connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, isComplete, error in
            guard let self, !self.stopped else { return }
            if let data, !data.isEmpty {
                channel.buffer.append(data)
                self.consume(channel)
            }
            if error != nil || isComplete {
                if channel.connection === connection { channel.connection = nil }
                connection.cancel()
                // 쉬는 동안 서버가 끊은 것(keep-alive 만료)이면 다음에 새로 맺으면 된다.
                if channel.request != nil { self.fail(channel, "closed") }
                return
            }
            self.receive(on: channel, connection: connection)
        }
    }

    /// HTTP/1.1 응답 하나를 꺼낸다. DoH 응답에는 Content-Length가 붙어 오는 게 표준이다.
    private func consume(_ channel: Channel) {
        guard channel.request != nil else { return }
        let buffer = channel.buffer
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }

        guard let header = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8)
        else {
            fail(channel, "header")
            return
        }
        let lines = header.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        guard let statusLine = lines.first, statusLine.contains(" 200") else {
            fail(channel, "http \(lines.first ?? "?")")
            return
        }
        guard let lengthLine = lines.first(where: { $0.lowercased().hasPrefix("content-length:") }),
              let length = Int(lengthLine.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
        else {
            // 길이를 모르면(chunked 등) 이 연결은 버리고 다시 시도한다.
            fail(channel, "no length")
            return
        }

        let bodyStart = headerEnd.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return }
        let bodyEnd = buffer.index(bodyStart, offsetBy: length)
        let body = [UInt8](buffer[bodyStart..<bodyEnd])
        channel.buffer.removeSubrange(buffer.startIndex..<bodyEnd)

        channel.timeoutToken += 1
        let request = channel.request
        channel.request = nil
        request?.completion(body)
        pump()
    }

    private func armTimeout(_ channel: Channel) {
        channel.timeoutToken += 1
        let token = channel.timeoutToken
        queue.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
            guard let self, !self.stopped,
                  channel.timeoutToken == token, channel.request != nil
            else { return }
            self.fail(channel, "timeout")
        }
    }

    /// 이 연결에서 처리 중이던 질의를 실패 처리한다. 한 번은 연결을 새로 맺어 다시
    /// 시도하고, 그래도 안 되면 평문 DNS로 떨어진다.
    private func fail(_ channel: Channel, _ reason: String) {
        guard let request = channel.request else { return }
        channel.request = nil
        channel.timeoutToken += 1
        channel.connection?.cancel()
        channel.connection = nil
        channel.buffer.removeAll(keepingCapacity: true)
        onFailure?(reason)

        if request.attempts < 2 {
            waiting.insert(request, at: 0)
        } else {
            resolvePlain(request.query, completion: request.completion)
        }
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
        queue.asyncAfter(deadline: .now() + Self.timeout) { finish(nil) }
    }
}
