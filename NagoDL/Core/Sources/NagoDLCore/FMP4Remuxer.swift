import Foundation

/// 조각 MP4(init + moof/mdat 조각들)를 보통 MP4로 다시 쓴다. 코덱 정보(stsd)는 그대로 옮겨서
/// H.264/HEVC/AAC 어떤 코덱이든 된다. 영상과 오디오가 다른 재생 목록이어도 한 파일로 합친다.
public enum FMP4Remuxer {
    public struct Result: Sendable, Equatable {
        public var hasVideo: Bool
        public var hasAudio: Bool
        public var samples: Int
    }

    struct BoxRef {
        var type: String
        /// 상자 시작(헤더 포함)
        var start: Int
        /// 내용 시작
        var body: Int
        var end: Int
    }

    struct TrackInfo {
        var id: UInt32
        var kind: MP4Writer.Kind?
        var timescale: UInt32
        var entry: [UInt8]
        var width: Int
        var height: Int
        var defaultDuration: UInt32 = 0
        var defaultSize: UInt32 = 0
        var defaultFlags: UInt32 = 0
        var editMediaTime: Int64?
        var emptyEdit: Double = 0
    }

    final class Output {
        let writer: MP4Writer
        var map: [String: Int] = [:]
        var durations: [Int: [UInt32]] = [:]
        var nextDTS: [Int: Int64] = [:]
        var offsets: [Int: Int64] = [:]
        var count = 0
        var hasVideo = false
        var hasAudio = false

        init(_ url: URL) throws {
            writer = try MP4Writer(url: url)
        }
    }

    public static func remux(initSegment: URL?, parts: [URL], audioInit: URL? = nil, audioParts: [URL] = [],
                             output: URL, progress: ((Double) -> Void)? = nil) throws -> Result {
        let out = try Output(output)
        let total = Double(max(1, parts.count + audioParts.count))
        var done = 0.0
        var groups: [(URL?, [URL], String)] = [(initSegment, parts, "m")]
        if !audioParts.isEmpty { groups.append((audioInit, audioParts, "a")) }
        for (initURL, files, tag) in groups {
            var tracks: [UInt32: TrackInfo] = [:]
            if let initURL {
                let data = try [UInt8](Data(contentsOf: initURL))
                tracks = try parseInit(data)
            }
            for file in files {
                let data = try [UInt8](Data(contentsOf: file, options: .alwaysMapped))
                // 조각마다 moov가 들어 있는 경우도 있다
                if tracks.isEmpty || data.count > 8 && boxes(data, 0, data.count).contains(where: { $0.type == "moov" }) {
                    let parsed = try parseInit(data)
                    if !parsed.isEmpty { tracks = parsed }
                }
                try readFragments(data, tracks: tracks, tag: tag, out: out)
                done += 1
                progress?(done / total)
            }
        }
        guard out.count > 0 else { throw RemuxError.noStreams }
        for (_, t) in out.map {
            if let d = out.durations[t] { out.writer.tracks[t].explicitDurations = d }
        }
        try out.writer.finish()
        return Result(hasVideo: out.hasVideo, hasAudio: out.hasAudio, samples: out.count)
    }

    // MARK: 상자 읽기

    static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    static func u64(_ b: [UInt8], _ i: Int) -> UInt64 {
        UInt64(u32(b, i)) << 32 | UInt64(u32(b, i + 4))
    }

    static func boxes(_ b: [UInt8], _ from: Int, _ to: Int) -> [BoxRef] {
        var out: [BoxRef] = []
        var i = from
        while i + 8 <= to {
            var size = Int(u32(b, i))
            let type = String(decoding: b[(i + 4)..<(i + 8)], as: UTF8.self)
            var body = i + 8
            if size == 1 {
                guard i + 16 <= to else { break }
                size = Int(u64(b, i + 8))
                body = i + 16
            } else if size == 0 {
                size = to - i
            }
            guard size >= body - i, i + size <= to else { break }
            out.append(BoxRef(type: type, start: i, body: body, end: i + size))
            i += size
        }
        return out
    }

    static func child(_ b: [UInt8], _ parent: BoxRef, _ type: String) -> BoxRef? {
        boxes(b, parent.body, parent.end).first { $0.type == type }
    }

    static func path(_ b: [UInt8], _ parent: BoxRef, _ types: [String]) -> BoxRef? {
        var cur = parent
        for t in types {
            guard let next = child(b, cur, t) else { return nil }
            cur = next
        }
        return cur
    }

    static func parseInit(_ b: [UInt8]) throws -> [UInt32: TrackInfo] {
        var tracks: [UInt32: TrackInfo] = [:]
        guard let moov = boxes(b, 0, b.count).first(where: { $0.type == "moov" }) else { return [:] }
        var movieTimescale: UInt32 = 1000
        if let mvhd = child(b, moov, "mvhd") {
            movieTimescale = max(1, u32(b, mvhd.body + (b[mvhd.body] == 1 ? 20 : 12)))
        }
        for trak in boxes(b, moov.body, moov.end) where trak.type == "trak" {
            guard let tkhd = child(b, trak, "tkhd"), let mdhd = path(b, trak, ["mdia", "mdhd"]),
                  let hdlr = path(b, trak, ["mdia", "hdlr"]), let stsd = path(b, trak, ["mdia", "minf", "stbl", "stsd"])
            else { continue }
            let tv = b[tkhd.body]
            let id = u32(b, tkhd.body + (tv == 1 ? 20 : 12))
            let width = Int(u32(b, tkhd.end - 8) >> 16)
            let height = Int(u32(b, tkhd.end - 4) >> 16)
            let mv = b[mdhd.body]
            let timescale = u32(b, mdhd.body + (mv == 1 ? 20 : 12))
            let handler = String(decoding: b[(hdlr.body + 8)..<(hdlr.body + 12)], as: UTF8.self)
            let entries = boxes(b, stsd.body + 8, stsd.end)
            guard let entry = entries.first else { continue }
            let format = entry.type
            if ["encv", "enca", "drmi", "drms"].contains(format) { throw RemuxError.unsupportedCodec("암호화(\(format))") }
            let kind: MP4Writer.Kind? = handler == "vide" ? .video : handler == "soun" ? .audio : nil
            var info = TrackInfo(id: id, kind: kind, timescale: timescale, entry: Array(b[entry.start..<entry.end]),
                                 width: width, height: height)
            // 편집 목록: 앞쪽 빈 구간 + 보이기 시작할 미디어 시각
            if let elst = path(b, trak, ["edts", "elst"]) {
                let v = b[elst.body]
                let n = Int(u32(b, elst.body + 4))
                var q = elst.body + 8
                for _ in 0..<n {
                    let size = v == 1 ? 20 : 12
                    guard q + size <= elst.end else { break }
                    let duration = v == 1 ? Int64(bitPattern: u64(b, q)) : Int64(u32(b, q))
                    let mediaTime = v == 1 ? Int64(bitPattern: u64(b, q + 8)) : Int64(Int32(bitPattern: u32(b, q + 4)))
                    q += size
                    if mediaTime == -1 {
                        info.emptyEdit += Double(duration) / Double(movieTimescale)
                    } else {
                        info.editMediaTime = mediaTime
                        break
                    }
                }
            }
            tracks[id] = info
        }
        if let mvex = child(b, moov, "mvex") {
            for trex in boxes(b, mvex.body, mvex.end) where trex.type == "trex" {
                let id = u32(b, trex.body + 4)
                tracks[id]?.defaultDuration = u32(b, trex.body + 12)
                tracks[id]?.defaultSize = u32(b, trex.body + 16)
                tracks[id]?.defaultFlags = u32(b, trex.body + 20)
            }
        }
        return tracks
    }

    static func readFragments(_ b: [UInt8], tracks: [UInt32: TrackInfo], tag: String, out: Output) throws {
        for moof in boxes(b, 0, b.count) where moof.type == "moof" {
            for traf in boxes(b, moof.body, moof.end) where traf.type == "traf" {
                guard let tfhd = child(b, traf, "tfhd") else { continue }
                let flags = u32(b, tfhd.body) & 0xFF_FFFF
                let id = u32(b, tfhd.body + 4)
                guard let info = tracks[id], let kind = info.kind else { continue }
                var p = tfhd.body + 8
                var base = moof.start
                if flags & 0x01 != 0 { base = Int(u64(b, p)); p += 8 }
                if flags & 0x02 != 0 { p += 4 }
                var defDuration = info.defaultDuration
                var defSize = info.defaultSize
                var defFlags = info.defaultFlags
                if flags & 0x08 != 0 { defDuration = u32(b, p); p += 4 }
                if flags & 0x10 != 0 { defSize = u32(b, p); p += 4 }
                if flags & 0x20 != 0 { defFlags = u32(b, p); p += 4 }

                let key = "\(tag)\(id)"
                let t: Int
                if let existing = out.map[key] {
                    t = existing
                } else {
                    t = out.writer.addTrack(kind: kind, timescale: info.timescale, sampleEntry: info.entry)
                    out.writer.setSampleEntry(t, info.entry, displayWidth: info.width, displayHeight: info.height)
                    out.writer.tracks[t].editMediaTime = info.editMediaTime
                    out.writer.tracks[t].emptyEdit = info.emptyEdit
                    out.map[key] = t
                    if kind == .video { out.hasVideo = true } else { out.hasAudio = true }
                }

                var dts: Int64 = out.nextDTS[t] ?? 0
                if let tfdt = child(b, traf, "tfdt") {
                    let v = b[tfdt.body]
                    let decode = Int64(v == 1 ? u64(b, tfdt.body + 4) : UInt64(u32(b, tfdt.body + 4)))
                    var offset = out.offsets[t] ?? 0
                    if let expected = out.nextDTS[t] {
                        let start = decode + offset
                        // 시각이 뒤로 가거나 크게 튀면 앞 조각 끝에 붙인다
                        if start < expected - Int64(info.timescale) || start > expected + 10 * Int64(info.timescale) {
                            offset = expected - decode
                        }
                    }
                    out.offsets[t] = offset
                    dts = decode + offset
                }

                var dataPos = base
                for trun in boxes(b, traf.body, traf.end) where trun.type == "trun" {
                    let version = b[trun.body]
                    let tf = u32(b, trun.body) & 0xFF_FFFF
                    let count = Int(u32(b, trun.body + 4))
                    var q = trun.body + 8
                    if tf & 0x01 != 0 {
                        dataPos = base + Int(Int32(bitPattern: u32(b, q)))
                        q += 4
                    }
                    var firstFlags: UInt32?
                    if tf & 0x04 != 0 { firstFlags = u32(b, q); q += 4 }
                    for k in 0..<count {
                        var duration = defDuration
                        var size = defSize
                        var sflags = k == 0 ? (firstFlags ?? defFlags) : defFlags
                        var cts: Int32 = 0
                        if tf & 0x100 != 0 { duration = u32(b, q); q += 4 }
                        if tf & 0x200 != 0 { size = u32(b, q); q += 4 }
                        if tf & 0x400 != 0 {
                            let f = u32(b, q)
                            q += 4
                            if !(k == 0 && firstFlags != nil) { sflags = f }
                        }
                        if tf & 0x800 != 0 {
                            let raw = u32(b, q)
                            q += 4
                            cts = version == 0 ? Int32(clamping: Int64(raw)) : Int32(bitPattern: raw)
                        }
                        let end = dataPos + Int(size)
                        guard dataPos >= 0, end <= b.count else { throw RemuxError.noStreams }
                        let sync = kind == .audio || (sflags >> 16) & 1 == 0
                        try out.writer.append(t, b[dataPos..<end], dts: dts, cts: cts, sync: sync)
                        out.durations[t, default: []].append(duration)
                        out.count += 1
                        dataPos = end
                        dts += Int64(duration)
                    }
                }
                out.nextDTS[t] = dts
            }
        }
    }
}
