import Foundation

/// MPEG-TS를 PES 단위로 푼다(PAT → PMT → 스트림별 PES).
final class TSDemuxer {
    struct PES {
        var pts: Int64?
        var dts: Int64?
        var payload: [UInt8]
    }

    static let packetSize = 188

    private(set) var pmtPID: Int?
    /// pid → stream_type
    private(set) var streams: [Int: UInt8] = [:]
    private var psi: [Int: [UInt8]] = [:]
    private var pes: [Int: [UInt8]] = [:]
    var onPES: ((Int, UInt8, PES) -> Void)?

    /// 파일 하나(또는 그 일부)를 넣는다. 188바이트 경계가 깨져 있으면 0x47을 찾아 다시 맞춘다.
    func feed(_ b: UnsafeRawBufferPointer) {
        let n = b.count
        var i = 0
        let size = Self.packetSize
        while i + size <= n {
            if b[i] != 0x47 {
                // 다음 동기 바이트(그 뒤 패킷도 0x47이면 확실)
                var j = i + 1
                while j + size <= n && !(b[j] == 0x47 && (j + size >= n || b[j + size] == 0x47)) { j += 1 }
                i = j
                continue
            }
            packet(b, i)
            i += size
        }
    }

    private func packet(_ b: UnsafeRawBufferPointer, _ at: Int) {
        let pusi = (b[at + 1] & 0x40) != 0
        let pid = Int(b[at + 1] & 0x1F) << 8 | Int(b[at + 2])
        let afc = (b[at + 3] >> 4) & 3
        var off = 4
        if afc & 2 != 0 { off += 1 + Int(b[at + 4]) }
        guard afc & 1 != 0, off < Self.packetSize else { return }
        let payload = UnsafeRawBufferPointer(rebasing: b[(at + off)..<(at + Self.packetSize)])
        if pid == 0 {
            section(pid, pusi, payload) { self.parsePAT($0) }
        } else if pid == pmtPID {
            section(pid, pusi, payload) { self.parsePMT($0) }
        } else if streams[pid] != nil {
            if pusi {
                emit(pid)
                pes[pid] = Array(payload)
            } else if pes[pid] != nil {
                pes[pid]!.append(contentsOf: payload)
            }
        }
    }

    private func section(_ pid: Int, _ pusi: Bool, _ payload: UnsafeRawBufferPointer, _ parse: ([UInt8]) -> Void) {
        if pusi {
            guard payload.count > 0 else { return }
            let pointer = Int(payload[0])
            guard 1 + pointer <= payload.count else { return }
            psi[pid] = Array(payload[(1 + pointer)...])
        } else if psi[pid] != nil {
            psi[pid]!.append(contentsOf: payload)
        } else {
            return
        }
        guard let buf = psi[pid], buf.count >= 3 else { return }
        let length = Int(buf[1] & 0x0F) << 8 | Int(buf[2])
        guard buf.count >= 3 + length else { return }
        parse(Array(buf[0..<(3 + length)]))
        psi[pid] = nil
    }

    private func parsePAT(_ s: [UInt8]) {
        guard s.count >= 12, s[0] == 0x00 else { return }
        let end = s.count - 4
        var i = 8
        while i + 4 <= end {
            let program = Int(s[i]) << 8 | Int(s[i + 1])
            let pid = Int(s[i + 2] & 0x1F) << 8 | Int(s[i + 3])
            if program != 0 {
                pmtPID = pid
                return
            }
            i += 4
        }
    }

    private func parsePMT(_ s: [UInt8]) {
        guard s.count >= 16, s[0] == 0x02 else { return }
        let infoLength = Int(s[10] & 0x0F) << 8 | Int(s[11])
        var i = 12 + infoLength
        let end = s.count - 4
        while i + 5 <= end {
            let type = s[i]
            let pid = Int(s[i + 1] & 0x1F) << 8 | Int(s[i + 2])
            let esLength = Int(s[i + 3] & 0x0F) << 8 | Int(s[i + 4])
            if streams[pid] == nil { streams[pid] = type }
            i += 5 + esLength
        }
    }

    /// 남은 PES를 다 내보낸다(파일 끝).
    func flush() {
        for pid in pes.keys.sorted() { emit(pid) }
    }

    private func emit(_ pid: Int) {
        guard let buf = pes[pid], let type = streams[pid] else { return }
        pes[pid] = nil
        guard buf.count >= 9, buf[0] == 0, buf[1] == 0, buf[2] == 1 else { return }
        let streamID = buf[3]
        // padding/private_2 등은 헤더 구조가 다르다
        if [0xBC, 0xBE, 0xBF, 0xF0, 0xF1, 0xFF, 0xF2, 0xF8].contains(streamID) { return }
        let length = Int(buf[4]) << 8 | Int(buf[5])
        let flags = buf[7]
        let headerLength = Int(buf[8])
        var pts: Int64?
        var dts: Int64?
        if flags & 0x80 != 0, buf.count >= 14 { pts = Self.timestamp(buf, 9) }
        if flags & 0x40 != 0, buf.count >= 19 { dts = Self.timestamp(buf, 14) }
        let start = 9 + headerLength
        let end = length > 0 ? min(buf.count, 6 + length) : buf.count
        guard start <= end else { return }
        onPES?(pid, type, PES(pts: pts, dts: dts, payload: Array(buf[start..<end])))
    }

    static func timestamp(_ b: [UInt8], _ i: Int) -> Int64 {
        (Int64(b[i] >> 1) & 0x07) << 30 | Int64(b[i + 1]) << 22 | (Int64(b[i + 2]) >> 1) << 15
            | Int64(b[i + 3]) << 7 | Int64(b[i + 4]) >> 1
    }
}
