import Foundation

/// 비트 단위 읽기(H.264 SPS 해석용). Exp-Golomb 지원.
struct BitReader {
    private let bytes: [UInt8]
    private var bit = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var bitsLeft: Int { bytes.count * 8 - bit }

    mutating func u(_ n: Int) -> UInt32? {
        guard n <= 32, bitsLeft >= n else { return nil }
        var v: UInt32 = 0
        for _ in 0..<n {
            let b = (bytes[bit >> 3] >> (7 - UInt8(bit & 7))) & 1
            v = (v << 1) | UInt32(b)
            bit += 1
        }
        return v
    }

    mutating func flag() -> Bool? { u(1).map { $0 == 1 } }

    /// unsigned Exp-Golomb
    mutating func ue() -> UInt32? {
        var zeros = 0
        while true {
            guard let b = u(1) else { return nil }
            if b == 1 { break }
            zeros += 1
            if zeros > 31 { return nil }
        }
        guard zeros > 0 else { return 0 }
        guard let rest = u(zeros) else { return nil }
        return (UInt32(1) << UInt32(zeros)) - 1 + rest
    }

    /// signed Exp-Golomb
    mutating func se() -> Int32? {
        guard let k = ue() else { return nil }
        let v = Int32((k + 1) / 2)
        return k % 2 == 0 ? -v : v
    }

    mutating func skip(_ n: Int) -> Bool {
        guard bitsLeft >= n else { return false }
        bit += n
        return true
    }
}

public enum H264 {
    public struct SPSInfo: Equatable, Sendable {
        public var profile: UInt8
        public var compatibility: UInt8
        public var level: UInt8
        public var width: Int
        public var height: Int
        public var sarWidth: Int
        public var sarHeight: Int
    }

    /// Annex B(00 00 01 시작 코드) 안의 NAL 범위들
    public static func nalRanges(_ b: [UInt8]) -> [Range<Int>] {
        var starts: [Int] = []
        var i = 0
        let n = b.count
        while i + 2 < n {
            if b[i] == 0 && b[i + 1] == 0 {
                if b[i + 2] == 1 {
                    starts.append(i + 3)
                    i += 3
                    continue
                }
                if b[i + 2] == 0 { i += 1; continue }
                i += 3
                continue
            }
            i += 1
        }
        var out: [Range<Int>] = []
        for (k, s) in starts.enumerated() {
            var e = k + 1 < starts.count ? starts[k + 1] - 3 : n
            // 다음 시작 코드 앞의 0(4바이트 시작 코드, trailing_zero)은 NAL이 아니다
            while e > s && b[e - 1] == 0 { e -= 1 }
            if e > s { out.append(s..<e) }
        }
        return out
    }

    /// 에뮬레이션 방지 바이트(00 00 03) 제거
    public static func unescape(_ nal: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(nal.count)
        var zeros = 0
        for byte in nal {
            if zeros >= 2 && byte == 3 {
                zeros = 0
                continue
            }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }

    static let sarTable: [(Int, Int)] = [
        (1, 1), (1, 1), (12, 11), (10, 11), (16, 11), (40, 33), (24, 11), (20, 11), (32, 11),
        (80, 33), (18, 11), (15, 11), (64, 33), (160, 99), (4, 3), (3, 2), (2, 1),
    ]

    /// SPS NAL(헤더 1바이트 포함)에서 크기와 화소 비율
    public static func parseSPS(_ nal: ArraySlice<UInt8>) -> SPSInfo? {
        let raw = unescape(nal)
        guard raw.count >= 4 else { return nil }
        var r = BitReader(Array(raw.dropFirst()))
        guard let profile = r.u(8), let compat = r.u(8), let level = r.u(8), r.ue() != nil else { return nil }
        var chroma: UInt32 = 1
        var separateColourPlane = false
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            guard let c = r.ue() else { return nil }
            chroma = c
            if chroma == 3 { separateColourPlane = r.flag() ?? false }
            guard r.ue() != nil, r.ue() != nil, r.flag() != nil, let scaling = r.flag() else { return nil }
            if scaling {
                for i in 0..<(chroma != 3 ? 8 : 12) {
                    guard let present = r.flag() else { return nil }
                    if present {
                        var last: Int32 = 8
                        var next: Int32 = 8
                        for _ in 0..<(i < 6 ? 16 : 64) where next != 0 {
                            guard let delta = r.se() else { return nil }
                            next = (last + delta + 256) % 256
                            last = next == 0 ? last : next
                        }
                    }
                }
            }
        }
        guard r.ue() != nil, let pocType = r.ue() else { return nil }
        if pocType == 0 {
            guard r.ue() != nil else { return nil }
        } else if pocType == 1 {
            guard r.flag() != nil, r.se() != nil, r.se() != nil, let cycle = r.ue() else { return nil }
            for _ in 0..<cycle { guard r.se() != nil else { return nil } }
        }
        guard r.ue() != nil, r.flag() != nil, let wMbs = r.ue(), let hMaps = r.ue(), let frameMbsOnly = r.flag() else { return nil }
        if !frameMbsOnly { guard r.flag() != nil else { return nil } }
        guard r.flag() != nil, let cropping = r.flag() else { return nil }
        var cl: UInt32 = 0, cr: UInt32 = 0, ct: UInt32 = 0, cb: UInt32 = 0
        if cropping {
            guard let a = r.ue(), let b = r.ue(), let c = r.ue(), let d = r.ue() else { return nil }
            cl = a; cr = b; ct = c; cb = d
        }
        let subW: Int, subH: Int
        switch (chroma, separateColourPlane) {
        case (0, _), (3, true): subW = 1; subH = 1
        case (1, _): subW = 2; subH = 2
        case (2, _): subW = 2; subH = 1
        default: subW = 1; subH = 1
        }
        let frameFactor = frameMbsOnly ? 1 : 2
        let cropX = (chroma == 0 || separateColourPlane) ? 1 : subW
        let cropY = ((chroma == 0 || separateColourPlane) ? 1 : subH) * frameFactor
        let width = Int(wMbs + 1) * 16 - cropX * Int(cl + cr)
        let height = frameFactor * Int(hMaps + 1) * 16 - cropY * Int(ct + cb)
        var sarW = 1, sarH = 1
        if let vui = r.flag(), vui, let arPresent = r.flag(), arPresent, let idc = r.u(8) {
            if idc == 255 {
                if let w = r.u(16), let h = r.u(16), w > 0, h > 0 { sarW = Int(w); sarH = Int(h) }
            } else if Int(idc) < sarTable.count {
                (sarW, sarH) = sarTable[Int(idc)]
            }
        }
        guard width > 0, height > 0 else { return nil }
        return SPSInfo(profile: UInt8(profile), compatibility: UInt8(compat), level: UInt8(level),
                       width: width, height: height, sarWidth: sarW, sarHeight: sarH)
    }

    /// avcC 상자 내용(구성 레코드)
    public static func avcConfiguration(sps: [UInt8], pps: [[UInt8]]) -> [UInt8] {
        var out: [UInt8] = [1, sps.count > 1 ? sps[1] : 0x42, sps.count > 2 ? sps[2] : 0, sps.count > 3 ? sps[3] : 0x1E,
                            0xFF, 0xE1]
        out += be16(sps.count) + sps
        out.append(UInt8(min(pps.count, 255)))
        for p in pps.prefix(255) { out += be16(p.count) + p }
        let profile = sps.count > 1 ? sps[1] : 0
        if [100, 110, 122, 144].contains(profile), let info = highProfileExtras(sps) {
            out += info
        }
        return out
    }

    /// High 계열 avcC 끝에 붙는 chroma_format/bit_depth(없으면 nil)
    static func highProfileExtras(_ sps: [UInt8]) -> [UInt8]? {
        let raw = unescape(sps[...])
        var r = BitReader(Array(raw.dropFirst()))
        guard r.u(8) != nil, r.u(8) != nil, r.u(8) != nil, r.ue() != nil,
              let chroma = r.ue() else { return nil }
        if chroma == 3 { _ = r.flag() }
        guard let luma = r.ue(), let chromaDepth = r.ue() else { return nil }
        return [0xFC | UInt8(chroma & 3), 0xF8 | UInt8(luma & 7), 0xF8 | UInt8(chromaDepth & 7), 0]
    }
}

public enum ADTS {
    public static let sampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    public struct Header: Equatable, Sendable {
        public var objectType: Int
        public var frequencyIndex: Int
        public var channels: Int
        public var frameLength: Int
        public var headerLength: Int

        public var sampleRate: Int { frequencyIndex < ADTS.sampleRates.count ? ADTS.sampleRates[frequencyIndex] : 44100 }

        /// AudioSpecificConfig 2바이트
        public var audioSpecificConfig: [UInt8] {
            let ot = UInt8(objectType & 0x1F)
            let fi = UInt8(frequencyIndex & 0x0F)
            let ch = UInt8(channels & 0x0F)
            return [(ot << 3) | (fi >> 1), ((fi & 1) << 7) | (ch << 3)]
        }
    }

    public static func parse(_ b: UnsafeRawBufferPointer, at i: Int) -> Header? {
        guard i + 7 <= b.count, b[i] == 0xFF, (b[i + 1] & 0xF6) == 0xF0 else { return nil }
        let protectionAbsent = (b[i + 1] & 1) == 1
        let profile = Int(b[i + 2] >> 6)
        let freq = Int((b[i + 2] >> 2) & 0x0F)
        let channels = Int((b[i + 2] & 1) << 2 | (b[i + 3] >> 6))
        let length = Int(b[i + 3] & 0x03) << 11 | Int(b[i + 4]) << 3 | Int(b[i + 5] >> 5)
        let headerLength = protectionAbsent ? 7 : 9
        guard freq < 13, length >= headerLength else { return nil }
        return Header(objectType: profile + 1, frequencyIndex: freq, channels: channels, frameLength: length,
                      headerLength: headerLength)
    }
}

@inline(__always) func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

@inline(__always) func be32(_ v: UInt32) -> [UInt8] {
    [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
}

@inline(__always) func be64(_ v: UInt64) -> [UInt8] {
    be32(UInt32(v >> 32)) + be32(UInt32(v & 0xFFFF_FFFF))
}
