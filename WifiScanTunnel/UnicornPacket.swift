import Foundation

// 유니콘 HTTPS(SNI 차단 우회)용. tun 인터페이스로는 "IP 패킷 한 개"가 그대로 들어오니
// 라이브러리를 붙이지 않고 필요한 만큼(IPv4/IPv6 + TCP/UDP)만 손으로 읽고 쓴다.
//
// 주소 타입을 IPAddr로 부르는 건 Network 프레임워크에 같은 이름의 프로토콜(IPAddress)이
// 있어서다(이 확장은 WireGuardKit 때문에 Network를 같이 쓴다).

@inline(__always)
func beUInt16(_ bytes: [UInt8], _ index: Int) -> UInt16 {
    (UInt16(bytes[index]) << 8) | UInt16(bytes[index + 1])
}

@inline(__always)
func beUInt32(_ bytes: [UInt8], _ index: Int) -> UInt32 {
    (UInt32(bytes[index]) << 24) | (UInt32(bytes[index + 1]) << 16)
        | (UInt32(bytes[index + 2]) << 8) | UInt32(bytes[index + 3])
}

@inline(__always)
func appendBE(_ bytes: inout [UInt8], _ value: UInt16) {
    bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    bytes.append(UInt8(truncatingIfNeeded: value))
}

@inline(__always)
func appendBE(_ bytes: inout [UInt8], _ value: UInt32) {
    bytes.append(UInt8(truncatingIfNeeded: value >> 24))
    bytes.append(UInt8(truncatingIfNeeded: value >> 16))
    bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    bytes.append(UInt8(truncatingIfNeeded: value))
}

/// 4바이트(IPv4) 또는 16바이트(IPv6) 주소.
struct IPAddr: Hashable, CustomStringConvertible {
    let bytes: [UInt8]

    init?(_ bytes: [UInt8]) {
        guard bytes.count == 4 || bytes.count == 16 else { return nil }
        self.bytes = bytes
    }

    var isIPv6: Bool { bytes.count == 16 }

    /// "1.1.1.1", "fd00::2" 같은 문자열에서 만든다.
    static func parse(_ text: String) -> IPAddr? {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            return IPAddr(withUnsafeBytes(of: v4.s_addr) { [UInt8]($0) })
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 {
            return IPAddr(withUnsafeBytes(of: v6) { [UInt8]($0) })
        }
        return nil
    }

    var description: String {
        if bytes.count == 4 {
            return bytes.map(String.init).joined(separator: ".")
        }
        return stride(from: 0, to: 16, by: 2)
            .map { String(format: "%x", beUInt16(bytes, $0)) }
            .joined(separator: ":")
    }
}

/// 체크섬: 16비트씩 더해서 접고 뒤집는다(RFC 1071).
enum Checksum {
    static func of(_ chunks: [[UInt8]]) -> UInt16 {
        var sum: UInt32 = 0
        var carryByte: UInt8?

        for chunk in chunks {
            var index = 0
            // 앞 덩어리가 홀수로 끝났으면 남은 한 바이트와 짝을 맞춘다.
            if let pending = carryByte {
                if chunk.isEmpty { continue }
                sum += (UInt32(pending) << 8) | UInt32(chunk[0])
                index = 1
                carryByte = nil
            }
            while index + 1 < chunk.count {
                sum += UInt32(beUInt16(chunk, index))
                index += 2
            }
            if index < chunk.count { carryByte = chunk[index] }
        }
        if let pending = carryByte { sum += UInt32(pending) << 8 }

        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(truncatingIfNeeded: sum)
    }

    /// TCP/UDP 체크섬에 들어가는 가짜 헤더(pseudo header).
    static func pseudoHeader(
        source: IPAddr, destination: IPAddr, protocolNumber: UInt8, length: Int
    ) -> [UInt8] {
        var header: [UInt8] = []
        header += source.bytes
        header += destination.bytes
        if source.isIPv6 {
            appendBE(&header, UInt32(length))
            header += [0, 0, 0, protocolNumber]
        } else {
            header.append(0)
            header.append(protocolNumber)
            appendBE(&header, UInt16(length))
        }
        return header
    }
}

/// IP 패킷 하나에서 꺼낸 정보.
struct IPDatagram {
    static let tcp: UInt8 = 6
    static let udp: UInt8 = 17

    var source: IPAddr
    var destination: IPAddr
    var protocolNumber: UInt8
    var payload: [UInt8]
    var isIPv6: Bool { source.isIPv6 }

    /// tun에서 읽은 패킷을 해석한다.
    /// 조각난 IPv4나 확장 헤더가 붙은 IPv6처럼 우리가 다루지 않는 건 nil로 버린다.
    static func parse(_ packet: Data) -> IPDatagram? {
        let bytes = [UInt8](packet)
        guard let first = bytes.first else { return nil }

        switch first >> 4 {
        case 4:
            guard bytes.count >= 20 else { return nil }
            let headerLength = Int(first & 0x0F) * 4
            guard headerLength >= 20, bytes.count >= headerLength else { return nil }

            // 조각(fragment)은 다루지 않는다. MF 비트나 offset이 있으면 버린다.
            let fragment = beUInt16(bytes, 6)
            guard fragment & 0x3FFF == 0 else { return nil }

            let total = Int(beUInt16(bytes, 2))
            let end = min(total > headerLength ? total : bytes.count, bytes.count)
            guard let source = IPAddr(Array(bytes[12..<16])),
                  let destination = IPAddr(Array(bytes[16..<20]))
            else { return nil }

            return IPDatagram(
                source: source,
                destination: destination,
                protocolNumber: bytes[9],
                payload: Array(bytes[headerLength..<end])
            )

        case 6:
            guard bytes.count >= 40 else { return nil }
            let nextHeader = bytes[6]
            guard nextHeader == tcp || nextHeader == udp else { return nil }

            let payloadLength = Int(beUInt16(bytes, 4))
            let end = min(40 + (payloadLength > 0 ? payloadLength : bytes.count - 40), bytes.count)
            guard end >= 40,
                  let source = IPAddr(Array(bytes[8..<24])),
                  let destination = IPAddr(Array(bytes[24..<40]))
            else { return nil }

            return IPDatagram(
                source: source,
                destination: destination,
                protocolNumber: nextHeader,
                payload: Array(bytes[40..<end])
            )

        default:
            return nil
        }
    }

    /// 전송 계층(payload)을 그대로 싣는 IP 패킷을 만든다.
    static func packet(
        source: IPAddr, destination: IPAddr, protocolNumber: UInt8, payload: [UInt8]
    ) -> Data {
        if source.isIPv6 {
            var header: [UInt8] = [0x60, 0, 0, 0]   // 버전 6, 트래픽 클래스/플로 레이블 0
            appendBE(&header, UInt16(payload.count))
            header.append(protocolNumber)
            header.append(64)                        // hop limit
            header += source.bytes
            header += destination.bytes
            return Data(header + payload)
        }

        var header: [UInt8] = [0x45, 0]              // 버전 4, 헤더 20바이트
        appendBE(&header, UInt16(20 + payload.count))
        appendBE(&header, UInt16.random(in: 0...UInt16.max))  // identification
        appendBE(&header, UInt16(0x4000))            // Don't Fragment
        header.append(64)                            // TTL
        header.append(protocolNumber)
        appendBE(&header, UInt16(0))                         // 체크섬 자리
        header += source.bytes
        header += destination.bytes

        let sum = Checksum.of([header])
        header[10] = UInt8(truncatingIfNeeded: sum >> 8)
        header[11] = UInt8(truncatingIfNeeded: sum)
        return Data(header + payload)
    }

    /// `writePackets(_:withProtocols:)`에 넘길 프로토콜 번호.
    var addressFamily: NSNumber { isIPv6 ? NSNumber(value: AF_INET6) : NSNumber(value: AF_INET) }
}

/// TCP 세그먼트 하나.
struct TCPSegment {
    struct Flags: OptionSet {
        let rawValue: UInt8
        static let fin = Flags(rawValue: 0x01)
        static let syn = Flags(rawValue: 0x02)
        static let rst = Flags(rawValue: 0x04)
        static let psh = Flags(rawValue: 0x08)
        static let ack = Flags(rawValue: 0x10)
    }

    var sourcePort: UInt16
    var destinationPort: UInt16
    var sequence: UInt32
    var acknowledgement: UInt32
    var flags: Flags
    var window: UInt16
    var payload: [UInt8]
    /// SYN에 붙어 오는 MSS 옵션(있을 때만).
    var maximumSegmentSize: UInt16?

    static func parse(_ bytes: [UInt8]) -> TCPSegment? {
        guard bytes.count >= 20 else { return nil }
        let dataOffset = Int(bytes[12] >> 4) * 4
        guard dataOffset >= 20, bytes.count >= dataOffset else { return nil }

        var mss: UInt16?
        var index = 20
        while index < dataOffset {
            let kind = bytes[index]
            if kind == 0 { break }              // End of options
            if kind == 1 { index += 1; continue }  // No-op
            guard index + 1 < dataOffset else { break }
            let length = Int(bytes[index + 1])
            guard length >= 2, index + length <= dataOffset else { break }
            if kind == 2, length == 4 { mss = beUInt16(bytes, index + 2) }
            index += length
        }

        return TCPSegment(
            sourcePort: beUInt16(bytes, 0),
            destinationPort: beUInt16(bytes, 2),
            sequence: beUInt32(bytes, 4),
            acknowledgement: beUInt32(bytes, 8),
            flags: Flags(rawValue: bytes[13] & 0x3F),
            window: beUInt16(bytes, 14),
            payload: Array(bytes[dataOffset...]),
            maximumSegmentSize: mss
        )
    }

    /// 체크섬까지 채운 TCP 바이트열.
    func serialized(source: IPAddr, destination: IPAddr) -> [UInt8] {
        var options: [UInt8] = []
        if let mss = maximumSegmentSize {
            options += [2, 4]           // kind 2, 길이 4 — 이것만으로 딱 4바이트다
            appendBE(&options, mss)
        }
        // TCP 헤더는 4바이트의 배수여야 하고, 헤더 길이 필드도 4로 나눈 값이다.
        // 옵션 길이가 어긋나면 End of Option List(0)로 채운다. 안 맞추면 헤더 길이가
        // 실제보다 작게 들어가고, 남은 옵션 바이트가 데이터로 읽혀 스트림이 깨진다.
        while options.count % 4 != 0 { options.append(0) }

        var header: [UInt8] = []
        appendBE(&header, sourcePort)
        appendBE(&header, destinationPort)
        appendBE(&header, sequence)
        appendBE(&header, acknowledgement)
        header.append(UInt8((20 + options.count) / 4) << 4)
        header.append(flags.rawValue)
        appendBE(&header, window)
        appendBE(&header, UInt16(0))    // 체크섬 자리
        appendBE(&header, UInt16(0))    // urgent pointer
        header += options

        let length = header.count + payload.count
        let pseudo = Checksum.pseudoHeader(
            source: source, destination: destination,
            protocolNumber: IPDatagram.tcp, length: length
        )
        let sum = Checksum.of([pseudo, header, payload])
        header[16] = UInt8(truncatingIfNeeded: sum >> 8)
        header[17] = UInt8(truncatingIfNeeded: sum)
        return header + payload
    }
}

/// UDP 데이터그램 하나.
struct UDPDatagram {
    var sourcePort: UInt16
    var destinationPort: UInt16
    var payload: [UInt8]

    static func parse(_ bytes: [UInt8]) -> UDPDatagram? {
        guard bytes.count >= 8 else { return nil }
        let length = Int(beUInt16(bytes, 4))
        let end = min(length >= 8 ? length : bytes.count, bytes.count)
        guard end >= 8 else { return nil }
        return UDPDatagram(
            sourcePort: beUInt16(bytes, 0),
            destinationPort: beUInt16(bytes, 2),
            payload: Array(bytes[8..<end])
        )
    }

    func serialized(source: IPAddr, destination: IPAddr) -> [UInt8] {
        var header: [UInt8] = []
        appendBE(&header, sourcePort)
        appendBE(&header, destinationPort)
        appendBE(&header, UInt16(8 + payload.count))
        appendBE(&header, UInt16(0))    // 체크섬 자리

        let pseudo = Checksum.pseudoHeader(
            source: source, destination: destination,
            protocolNumber: IPDatagram.udp, length: 8 + payload.count
        )
        var sum = Checksum.of([pseudo, header, payload])
        // UDP에서 0은 "체크섬 없음"을 뜻하므로 0xFFFF로 바꿔 보낸다.
        if sum == 0 { sum = 0xFFFF }
        header[6] = UInt8(truncatingIfNeeded: sum >> 8)
        header[7] = UInt8(truncatingIfNeeded: sum)
        return header + payload
    }
}

/// TCP 순서 번호 비교(32비트 wrap-around를 고려).
@inline(__always)
func sequenceLessThanOrEqual(_ a: UInt32, _ b: UInt32) -> Bool {
    Int32(bitPattern: a &- b) <= 0
}

@inline(__always)
func sequenceLessThan(_ a: UInt32, _ b: UInt32) -> Bool {
    Int32(bitPattern: a &- b) < 0
}
