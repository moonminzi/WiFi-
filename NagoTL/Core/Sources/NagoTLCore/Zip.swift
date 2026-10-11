import Foundation

/// ZIP/CBZ 읽기(저장·deflate)와 쓰기(저장). 만화책 묶음 가져오기·내보내기용.
public enum ZipError: Error, Equatable, LocalizedError {
    case notZip
    case corrupt(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .notZip: return "ZIP 파일이 아니에요"
        case let .corrupt(m): return "ZIP 파일이 깨졌어요(\(m))"
        case let .unsupported(m): return "지원하지 않는 ZIP이에요(\(m))"
        }
    }
}

public struct ZipEntry: Sendable, Equatable {
    public var name: String
    public var method: Int
    public var compressedSize: Int
    public var size: Int
    public var crc: UInt32
    public var localOffset: Int
    public var encrypted: Bool
    public var isDirectory: Bool { name.hasSuffix("/") }
}

public struct ZipReader {
    public let data: Data
    public let entries: [ZipEntry]

    public init(data: Data) throws {
        self.data = data
        entries = try ZipReader.readDirectory(data)
    }

    public init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    static func u16(_ d: Data, _ o: Int) -> Int {
        let b = d.startIndex + o
        return Int(d[b]) | Int(d[b + 1]) << 8
    }

    static func u32(_ d: Data, _ o: Int) -> Int {
        let b = d.startIndex + o
        return Int(d[b]) | Int(d[b + 1]) << 8 | Int(d[b + 2]) << 16 | Int(d[b + 3]) << 24
    }

    static func u64(_ d: Data, _ o: Int) -> Int {
        u32(d, o) | u32(d, o + 4) << 32
    }

    static func readDirectory(_ d: Data) throws -> [ZipEntry] {
        guard d.count >= 22 else { throw ZipError.notZip }
        // 끝에서 중앙 디렉터리 끝 표시를 찾는다(주석이 붙어 있을 수 있다)
        var eocd = -1
        var i = d.count - 22
        let stop = max(0, d.count - 22 - 65_535)
        while i >= stop {
            if u32(d, i) == 0x0605_4B50 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notZip }
        var count = u16(d, eocd + 10)
        var cdSize = u32(d, eocd + 12)
        var cdOffset = u32(d, eocd + 16)
        if count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            // ZIP64
            let loc = eocd - 20
            guard loc >= 0, u32(d, loc) == 0x0706_4B50 else { throw ZipError.corrupt("zip64 locator") }
            let z = u64(d, loc + 8)
            guard z >= 0, z + 56 <= d.count, u32(d, z) == 0x0606_4B50 else { throw ZipError.corrupt("zip64 eocd") }
            count = u64(d, z + 32)
            cdSize = u64(d, z + 40)
            cdOffset = u64(d, z + 48)
        }
        guard cdOffset >= 0, cdOffset + cdSize <= d.count else { throw ZipError.corrupt("directory offset") }
        var out: [ZipEntry] = []
        out.reserveCapacity(count)
        var p = cdOffset
        for _ in 0..<count {
            guard p + 46 <= d.count, u32(d, p) == 0x0201_4B50 else { throw ZipError.corrupt("directory entry") }
            let flags = u16(d, p + 8)
            let method = u16(d, p + 10)
            let crc = UInt32(u32(d, p + 16))
            var csize = u32(d, p + 20)
            var size = u32(d, p + 24)
            let nlen = u16(d, p + 28), xlen = u16(d, p + 30), clen = u16(d, p + 32)
            var local = u32(d, p + 42)
            guard p + 46 + nlen + xlen + clen <= d.count else { throw ZipError.corrupt("entry name") }
            let nameBytes = d.subdata(in: (d.startIndex + p + 46)..<(d.startIndex + p + 46 + nlen))
            let name = String(data: nameBytes, encoding: .utf8)
                ?? String(data: nameBytes, encoding: .shiftJIS)
                ?? String(data: nameBytes, encoding: .isoLatin1) ?? ""
            // ZIP64 추가 정보
            var x = p + 46 + nlen
            let xend = x + xlen
            while x + 4 <= xend {
                let id = u16(d, x), len = u16(d, x + 2)
                if id == 0x0001 {
                    var q = x + 4
                    if size == 0xFFFF_FFFF, q + 8 <= x + 4 + len { size = u64(d, q); q += 8 }
                    if csize == 0xFFFF_FFFF, q + 8 <= x + 4 + len { csize = u64(d, q); q += 8 }
                    if local == 0xFFFF_FFFF, q + 8 <= x + 4 + len { local = u64(d, q) }
                }
                x += 4 + len
            }
            out.append(ZipEntry(name: name.replacingOccurrences(of: "\\", with: "/"), method: method,
                                compressedSize: csize, size: size, crc: crc, localOffset: local,
                                encrypted: flags & 1 != 0))
            p += 46 + nlen + xlen + clen
        }
        return out
    }

    /// 파일 하나를 푼다
    public func extract(_ e: ZipEntry) throws -> Data {
        guard !e.encrypted else { throw ZipError.unsupported("암호") }
        let o = e.localOffset
        guard o >= 0, o + 30 <= data.count, ZipReader.u32(data, o) == 0x0403_4B50 else {
            throw ZipError.corrupt("local header")
        }
        let start = o + 30 + ZipReader.u16(data, o + 26) + ZipReader.u16(data, o + 28)
        guard start + e.compressedSize <= data.count else { throw ZipError.corrupt("data range") }
        let raw = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + e.compressedSize))
        switch e.method {
        case 0:
            return raw
        case 8:
            return Data(try Inflate.inflate([UInt8](raw), expectedSize: e.size))
        default:
            throw ZipError.unsupported("압축 방식 \(e.method)")
        }
    }

    /// 만화 페이지로 쓸 그림 파일들(이름 순서: 2가 10보다 앞)
    public var imageEntries: [ZipEntry] {
        files(withExtensions: ["jpg", "jpeg", "png", "webp", "gif", "bmp", "heic", "heif", "avif", "tif", "tiff"])
    }

    /// 여러 권을 한 ZIP에 묶은 경우 안에 든 책들(ZIP/CBZ/PDF, 이름 순서)
    public var innerBooks: [ZipEntry] {
        files(withExtensions: ["zip", "cbz", "pdf"])
    }

    /// 폴더·맥 부가 파일(__MACOSX, ._이름)·숨김 파일을 뺀, 확장자가 맞는 파일들
    func files(withExtensions exts: Set<String>) -> [ZipEntry] {
        entries.filter { e in
            guard !e.isDirectory, !e.name.hasPrefix("__MACOSX/") else { return false }
            let last = e.name.split(separator: "/").last.map(String.init) ?? e.name
            guard !last.hasPrefix(".") else { return false }
            return exts.contains((last as NSString).pathExtension.lowercased())
        }.sorted { naturalLess($0.name, $1.name) }
    }
}

/// 숫자는 숫자로 비교하는 이름 순서("p2" < "p10")
public func naturalLess(_ a: String, _ b: String) -> Bool {
    let x = Array(a.lowercased()), y = Array(b.lowercased())
    var i = 0, j = 0
    while i < x.count && j < y.count {
        if x[i].isNumber && y[j].isNumber {
            var ni = i, nj = j
            while ni < x.count && x[ni].isNumber { ni += 1 }
            while nj < y.count && y[nj].isNumber { nj += 1 }
            let sa = String(x[i..<ni]).drop { $0 == "0" }, sb = String(y[j..<nj]).drop { $0 == "0" }
            if sa.count != sb.count { return sa.count < sb.count }
            if sa != sb { return sa < sb }
            i = ni
            j = nj
        } else {
            if x[i] != y[j] { return x[i] < y[j] }
            i += 1
            j += 1
        }
    }
    return x.count - i < y.count - j
}

/// 압축하지 않고(그림은 이미 압축돼 있다) 바로 파일에 쓰는 ZIP
public final class ZipWriter {
    let handle: FileHandle
    var offset = 0
    var central = Data()
    var count = 0

    public init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw ZipError.corrupt("파일을 만들 수 없음")
        }
        handle = try FileHandle(forWritingTo: url)
    }

    static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    static func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }

    public func add(name: String, data: Data, date: Date = Date()) throws {
        let nameData = Data(name.utf8)
        let crc = Int(CRC32.checksum(data))
        let (dosTime, dosDate) = ZipWriter.dos(date)
        var local = Data()
        local.append(contentsOf: ZipWriter.le32(0x0403_4B50))
        local.append(contentsOf: ZipWriter.le16(20))
        local.append(contentsOf: ZipWriter.le16(0x0800)) // UTF-8 이름
        local.append(contentsOf: ZipWriter.le16(0))
        local.append(contentsOf: ZipWriter.le16(dosTime))
        local.append(contentsOf: ZipWriter.le16(dosDate))
        local.append(contentsOf: ZipWriter.le32(crc))
        local.append(contentsOf: ZipWriter.le32(data.count))
        local.append(contentsOf: ZipWriter.le32(data.count))
        local.append(contentsOf: ZipWriter.le16(nameData.count))
        local.append(contentsOf: ZipWriter.le16(0))
        local.append(nameData)
        handle.write(local)
        handle.write(data)

        var c = Data()
        c.append(contentsOf: ZipWriter.le32(0x0201_4B50))
        c.append(contentsOf: ZipWriter.le16(20))
        c.append(contentsOf: ZipWriter.le16(20))
        c.append(contentsOf: ZipWriter.le16(0x0800))
        c.append(contentsOf: ZipWriter.le16(0))
        c.append(contentsOf: ZipWriter.le16(dosTime))
        c.append(contentsOf: ZipWriter.le16(dosDate))
        c.append(contentsOf: ZipWriter.le32(crc))
        c.append(contentsOf: ZipWriter.le32(data.count))
        c.append(contentsOf: ZipWriter.le32(data.count))
        c.append(contentsOf: ZipWriter.le16(nameData.count))
        c.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        c.append(contentsOf: ZipWriter.le32(offset))
        c.append(nameData)
        central.append(c)
        offset += local.count + data.count
        count += 1
    }

    public func finish() throws {
        var end = Data()
        end.append(contentsOf: ZipWriter.le32(0x0605_4B50))
        end.append(contentsOf: [0, 0, 0, 0])
        end.append(contentsOf: ZipWriter.le16(count))
        end.append(contentsOf: ZipWriter.le16(count))
        end.append(contentsOf: ZipWriter.le32(central.count))
        end.append(contentsOf: ZipWriter.le32(offset))
        end.append(contentsOf: [0, 0])
        handle.write(central)
        handle.write(end)
        try handle.close()
    }

    static func dos(_ date: Date) -> (Int, Int) {
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        let time = (c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2
        let day = max(0, (c.year ?? 1980) - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1)
        return (time, day)
    }
}

public enum CRC32 {
    static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for b in p { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        return c ^ 0xFFFF_FFFF
    }
}

/// DEFLATE(RFC 1951) 풀기
public enum Inflate {
    struct Bits {
        let data: [UInt8]
        var pos = 0
        var buf: UInt64 = 0
        var count = 0
        /// 입력 끝을 넘어 0으로 채워 읽은 비트 수(실제로 쓰면 깨진 것)
        var padded = 0

        mutating func fill(_ n: Int) {
            while count < n {
                if pos < data.count {
                    buf |= UInt64(data[pos]) << UInt64(count)
                    pos += 1
                } else {
                    padded += 8
                }
                count += 8
            }
        }

        mutating func take(_ n: Int) throws -> Int {
            if n == 0 { return 0 }
            fill(n)
            let v = Int(buf & ((1 << UInt64(n)) - 1))
            buf >>= UInt64(n)
            count -= n
            if padded > count { throw ZipError.corrupt("deflate: 입력이 모자람") }
            return v
        }

        mutating func alignToByte() {
            let drop = count % 8
            buf >>= UInt64(drop)
            count -= drop
        }
    }

    struct Huffman {
        /// (기호 << 4) | 길이, 길이 0 = 없는 부호
        var table: [UInt16]
        var maxLen: Int

        init(lengths: [Int]) throws {
            maxLen = max(1, lengths.max() ?? 1)
            table = [UInt16](repeating: 0, count: 1 << maxLen)
            var blCount = [Int](repeating: 0, count: 16)
            for l in lengths where l > 0 { blCount[l] += 1 }
            var next = [Int](repeating: 0, count: 16)
            var code = 0
            for bits in 1...15 {
                code = (code + blCount[bits - 1]) << 1
                next[bits] = code
            }
            for (sym, len) in lengths.enumerated() where len > 0 {
                let c = next[len]
                next[len] += 1
                // 비트 순서를 뒤집는다(deflate는 낮은 비트부터 읽는다)
                var r = 0
                for k in 0..<len where c & (1 << k) != 0 { r |= 1 << (len - 1 - k) }
                var k = r
                while k < table.count {
                    table[k] = UInt16(sym << 4 | len)
                    k += 1 << len
                }
            }
        }

        func decode(_ b: inout Bits) throws -> Int {
            b.fill(maxLen)
            let e = table[Int(b.buf & ((1 << UInt64(maxLen)) - 1))]
            let len = Int(e & 15)
            guard len > 0 else { throw ZipError.corrupt("deflate: 없는 부호") }
            b.buf >>= UInt64(len)
            b.count -= len
            if b.padded > b.count { throw ZipError.corrupt("deflate: 입력이 모자람") }
            return Int(e >> 4)
        }
    }

    static let lenBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115,
                          131, 163, 195, 227, 258]
    static let lenExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537,
                           2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    static let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12,
                            13, 13]
    static let clOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    static let fixed: (Huffman, Huffman) = {
        var l = [Int](repeating: 8, count: 288)
        for i in 144..<256 { l[i] = 9 }
        for i in 256..<280 { l[i] = 7 }
        // swiftlint:disable:next force_try
        return (try! Huffman(lengths: l), try! Huffman(lengths: [Int](repeating: 5, count: 30)))
    }()

    /// 풀어 쓴 결과(미리 잡은 버퍼에 쓰고, 모자라면 늘린다 — 자기 자신을 조각으로 복사하면 버퍼 전체가 복사돼 느려진다)
    struct Output {
        var buf: [UInt8]
        var n = 0

        init(capacity: Int) {
            buf = [UInt8](repeating: 0, count: max(1024, capacity))
        }

        @inline(__always) mutating func reserve(_ extra: Int) {
            if n + extra > buf.count {
                buf.append(contentsOf: repeatElement(0, count: max(buf.count, extra)))
            }
        }

        @inline(__always) mutating func byte(_ b: UInt8) {
            reserve(1)
            buf[n] = b
            n += 1
        }

        /// 거리 d 앞에서 len 바이트를 이어 붙인다(겹쳐도 된다: 한 바이트씩)
        @inline(__always) mutating func copy(distance d: Int, length len: Int) {
            reserve(len)
            buf.withUnsafeMutableBufferPointer { p in
                var src = n - d, dst = n
                for _ in 0..<len {
                    p[dst] = p[src]
                    dst += 1
                    src += 1
                }
            }
            n += len
        }

        mutating func append(_ bytes: ArraySlice<UInt8>) {
            reserve(bytes.count)
            buf.replaceSubrange(n..<(n + bytes.count), with: bytes)
            n += bytes.count
        }

        var result: [UInt8] { Array(buf[0..<n]) }
    }

    public static func inflate(_ input: [UInt8], expectedSize: Int? = nil) throws -> [UInt8] {
        var b = Bits(data: input)
        var out = Output(capacity: expectedSize ?? input.count * 3)
        var last = false
        while !last {
            last = try b.take(1) == 1
            switch try b.take(2) {
            case 0:
                b.alignToByte()
                let len = try b.take(16), nlen = try b.take(16)
                guard len == (~nlen & 0xFFFF) else { throw ZipError.corrupt("deflate: 저장 블록 길이") }
                // 비트 버퍼에 남은 바이트부터
                var left = len
                while left > 0 && b.count >= 8 {
                    out.byte(UInt8(try b.take(8)))
                    left -= 1
                }
                guard b.pos + left <= input.count else { throw ZipError.corrupt("deflate: 저장 블록 범위") }
                out.append(input[b.pos..<(b.pos + left)])
                b.pos += left
            case 1:
                try codes(&b, &out, fixed.0, fixed.1)
            case 2:
                let hlit = try b.take(5) + 257, hdist = try b.take(5) + 1, hclen = try b.take(4) + 4
                var cl = [Int](repeating: 0, count: 19)
                for i in 0..<hclen { cl[clOrder[i]] = try b.take(3) }
                let clh = try Huffman(lengths: cl)
                var lengths: [Int] = []
                lengths.reserveCapacity(hlit + hdist)
                while lengths.count < hlit + hdist {
                    let sym = try clh.decode(&b)
                    switch sym {
                    case 0...15:
                        lengths.append(sym)
                    case 16:
                        guard let prev = lengths.last else { throw ZipError.corrupt("deflate: 반복할 길이 없음") }
                        lengths.append(contentsOf: [Int](repeating: prev, count: 3 + (try b.take(2))))
                    case 17:
                        lengths.append(contentsOf: [Int](repeating: 0, count: 3 + (try b.take(3))))
                    default:
                        lengths.append(contentsOf: [Int](repeating: 0, count: 11 + (try b.take(7))))
                    }
                }
                guard lengths.count == hlit + hdist else { throw ZipError.corrupt("deflate: 길이 표") }
                let lit = try Huffman(lengths: Array(lengths[0..<hlit]))
                let dist = try Huffman(lengths: Array(lengths[hlit...]))
                try codes(&b, &out, lit, dist)
            default:
                throw ZipError.corrupt("deflate: 블록 종류")
            }
        }
        return out.result
    }

    static func codes(_ b: inout Bits, _ out: inout Output, _ lit: Huffman, _ dist: Huffman) throws {
        while true {
            let sym = try lit.decode(&b)
            if sym < 256 {
                out.byte(UInt8(sym))
            } else if sym == 256 {
                return
            } else {
                let li = sym - 257
                guard li < 29 else { throw ZipError.corrupt("deflate: 길이 부호") }
                let len = lenBase[li] + (try b.take(lenExtra[li]))
                let di = try dist.decode(&b)
                guard di < 30 else { throw ZipError.corrupt("deflate: 거리 부호") }
                let d = distBase[di] + (try b.take(distExtra[di]))
                guard d <= out.n else { throw ZipError.corrupt("deflate: 거리") }
                out.copy(distance: d, length: len)
            }
        }
    }
}
