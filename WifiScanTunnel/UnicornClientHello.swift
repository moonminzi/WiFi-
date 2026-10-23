import Foundation

/// TLS ClientHello 안에서 도메인 이름(SNI)이 어디에 적혀 있는지 찾는다.
///
/// SNI 차단 장비는 TLS 첫 패킷에 평문으로 들어 있는 이 도메인 이름을 보고 연결을 끊는다.
/// 이름이 한 덩어리로 보이지 않게 그 사이를 끊어 보내는 게 이 기능의 전부다.
enum TLSClientHello {

    struct Parsed {
        /// 레코드 전체 길이(헤더 5바이트 포함).
        let recordLength: Int
        /// 레코드 버전 바이트 2개. 새로 만드는 레코드에 그대로 쓴다.
        let versionMajor: UInt8
        let versionMinor: UInt8
        /// 레코드 본문(= 핸드셰이크 메시지) 범위. 입력 배열 기준 위치.
        let bodyRange: Range<Int>
        /// SNI 호스트 이름이 적힌 범위. 입력 배열 기준 위치.
        let hostnameRange: Range<Int>?
        let hostname: String?
    }

    /// TLS 핸드셰이크 레코드처럼 보이는지. 첫 바이트만으로 빠르게 가른다.
    static func looksLikeHandshake(_ bytes: [UInt8]) -> Bool {
        guard let first = bytes.first else { return true }   // 아직 판단 불가 → 더 기다림
        guard first == 0x16 else { return false }
        if bytes.count >= 2 && bytes[1] != 0x03 { return false }
        return true
    }

    /// 레코드 하나를 다 받으려면 몇 바이트가 필요한지. 헤더가 아직 덜 왔으면 nil.
    static func expectedRecordLength(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 5 else { return nil }
        return 5 + Int(beUInt16(bytes, 3))
    }

    /// ClientHello를 해석한다. 레코드가 덜 왔거나 ClientHello가 아니면 nil.
    static func parse(_ bytes: [UInt8]) -> Parsed? {
        guard bytes.count >= 5, bytes[0] == 0x16 else { return nil }
        let bodyLength = Int(beUInt16(bytes, 3))
        guard bodyLength > 0, bytes.count >= 5 + bodyLength else { return nil }

        let body = 5..<(5 + bodyLength)
        // 핸드셰이크 헤더: 타입 1바이트 + 길이 3바이트
        guard bodyLength >= 4, bytes[body.lowerBound] == 0x01 else { return nil }

        let parsedHostname = hostnameRange(in: bytes, body: body)
        var hostname: String?
        if let range = parsedHostname {
            hostname = String(bytes: bytes[range], encoding: .utf8)
        }

        return Parsed(
            recordLength: 5 + bodyLength,
            versionMajor: bytes[1],
            versionMinor: bytes[2],
            bodyRange: body,
            hostnameRange: parsedHostname,
            hostname: hostname
        )
    }

    /// ClientHello 본문을 따라 내려가 server_name 확장을 찾는다.
    private static func hostnameRange(in bytes: [UInt8], body: Range<Int>) -> Range<Int>? {
        var cursor = body.lowerBound + 4      // 핸드셰이크 헤더
        let end = body.upperBound

        func need(_ count: Int) -> Bool { cursor + count <= end }

        guard need(2 + 32) else { return nil }
        cursor += 2 + 32                      // 버전 + 랜덤

        guard need(1) else { return nil }
        cursor += 1 + Int(bytes[cursor])      // 세션 ID

        guard need(2) else { return nil }
        cursor += 2 + Int(beUInt16(bytes, cursor))   // 암호 스위트 목록

        guard need(1) else { return nil }
        cursor += 1 + Int(bytes[cursor])      // 압축 방식 목록

        guard need(2) else { return nil }
        let extensionsLength = Int(beUInt16(bytes, cursor))
        cursor += 2
        let extensionsEnd = min(cursor + extensionsLength, end)

        while cursor + 4 <= extensionsEnd {
            let type = beUInt16(bytes, cursor)
            let length = Int(beUInt16(bytes, cursor + 2))
            let valueStart = cursor + 4
            guard valueStart + length <= extensionsEnd else { return nil }

            if type == 0x0000 {               // server_name
                // 목록 길이 2 + 이름 타입 1 + 이름 길이 2 + 이름
                guard length >= 5 else { return nil }
                let nameType = bytes[valueStart + 2]
                guard nameType == 0 else { return nil }
                let nameLength = Int(beUInt16(bytes, valueStart + 3))
                let nameStart = valueStart + 5
                guard nameLength > 0, nameStart + nameLength <= valueStart + length else { return nil }
                return nameStart..<(nameStart + nameLength)
            }
            cursor = valueStart + length
        }
        return nil
    }
}

/// ClientHello를 설정대로 쪼갠다.
///
/// 결과는 "한 번의 send()로 보낼 덩어리" 목록이다. 세그먼트 분할을 끄면 한 덩어리만,
/// 켜면 여러 덩어리가 나오고 호출하는 쪽이 사이를 살짝 띄워 보낸다.
struct ClientHelloFragmenter {
    /// 쪼갠 결과. `pieces`는 한 번의 send()로 나갈 덩어리들이고,
    /// `hostname`은 로그에 남길 접속 도메인(없을 수도 있다).
    struct Split {
        let pieces: [[UInt8]]
        let hostname: String?
    }

    let settings: UnicornSettings

    /// 쪼갤 수 있으면 조각 목록을, 건드릴 게 없으면 nil을 돌려준다.
    func split(_ bytes: [UInt8]) -> Split? {
        guard settings.strategy != .off,
              let hello = TLSClientHello.parse(bytes)
        else { return nil }

        let body = Array(bytes[hello.bodyRange])
        // 레코드 뒤에 다른 데이터가 붙어 있으면 손대지 않고 그대로 뒤에 붙인다.
        let trailing = Array(bytes[hello.recordLength...])

        let cuts = splitPoints(hello: hello, bodyCount: body.count)
        guard !cuts.isEmpty else { return nil }

        var chunks: [[UInt8]] = []
        var start = 0
        for cut in cuts {
            chunks.append(Array(body[start..<cut]))
            start = cut
        }
        chunks.append(Array(body[start...]))

        var pieces: [[UInt8]] = []
        if settings.strategy.splitsRecord {
            // 조각마다 TLS 레코드를 새로 씌운다. 핸드셰이크 메시지가 여러 레코드에
            // 걸쳐도 되는 건 TLS 규격에 들어 있어서 서버는 그대로 받아 준다.
            pieces = chunks.map { record(hello: hello, body: $0) }
        } else {
            // 레코드는 하나로 두고, 보낸 바이트열만 잘라 TCP 패킷을 나눈다.
            let whole = record(hello: hello, body: body)
            var offset = 0
            for cut in cuts {
                let end = 5 + cut
                pieces.append(Array(whole[offset..<end]))
                offset = end
            }
            pieces.append(Array(whole[offset...]))
        }

        if !settings.strategy.splitsSegment {
            // 세그먼트는 나누지 않으므로 한 번에 보낸다(레코드 경계만 남는다).
            pieces = [pieces.flatMap { $0 }]
        }
        if !trailing.isEmpty { pieces.append(trailing) }
        return Split(pieces: pieces, hostname: hello.hostname)
    }

    private func record(hello: TLSClientHello.Parsed, body: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x16, hello.versionMajor, hello.versionMinor]
        appendBE(&out, UInt16(body.count))
        out += body
        return out
    }

    /// 레코드 본문 기준으로 끊을 위치들(오름차순, 중복 없음).
    private func splitPoints(hello: TLSClientHello.Parsed, bodyCount: Int) -> [Int] {
        guard bodyCount >= 2 else { return [] }
        let pieces = settings.normalizedPieces

        if settings.splitInsideHostname, let range = hello.hostnameRange {
            // 호스트 이름 글자 사이를 끊는다. 앞도 뒤도 온전한 이름이 남지 않게
            // 이름 안쪽을 고르게 나눈다.
            let start = range.lowerBound - hello.bodyRange.lowerBound
            let length = range.count
            if length >= 2 {
                let cutCount = min(pieces - 1, length - 1)
                var cuts: [Int] = []
                for index in 1...max(cutCount, 1) {
                    let offset = start + (length * index) / (cutCount + 1)
                    let clamped = min(max(offset, start + 1), start + length - 1)
                    cuts.append(clamped)
                }
                return normalize(cuts, bodyCount: bodyCount)
            }
        }

        // 이름을 못 찾았거나 끄고 쓸 때: 본문을 고르게 나눈다.
        var cuts: [Int] = []
        for index in 1..<pieces {
            cuts.append((bodyCount * index) / pieces)
        }
        return normalize(cuts, bodyCount: bodyCount)
    }

    private func normalize(_ cuts: [Int], bodyCount: Int) -> [Int] {
        var seen = Set<Int>()
        var result: [Int] = []
        for cut in cuts.sorted() where cut > 0 && cut < bodyCount && !seen.contains(cut) {
            seen.insert(cut)
            result.append(cut)
        }
        return result
    }
}
