import Foundation

/// 보통(조각 없는) MP4를 쓴다: ftyp → mdat(샘플을 들어오는 대로) → moov(표는 마지막에).
final class MP4Writer {
    enum Kind { case video, audio }

    final class Track {
        let kind: Kind
        let timescale: UInt32
        var sampleEntry: [UInt8]
        var width: Int
        var height: Int
        var sizes: [UInt32] = []
        var dts: [Int64] = []
        var cts: [Int32] = []
        var syncSamples: [UInt32] = []
        var allSync = true
        var chunkOffsets: [UInt64] = []
        var chunkCounts: [UInt32] = []
        var lastEnd: Int64 = -1
        /// 정해 둔 길이(오디오처럼 샘플 길이가 고정이면). 없으면 다음 샘플과의 차이로 정한다.
        var explicitDurations: [UInt32]?
        /// 원본 편집 목록이 표시를 시작하라고 한 미디어 시각(AAC 앞부분 무음·B프레임 지연 보정)
        var editMediaTime: Int64?
        /// 원본 편집 목록의 앞쪽 빈 구간(초)
        var emptyEdit: Double = 0

        init(kind: Kind, timescale: UInt32, sampleEntry: [UInt8], width: Int, height: Int) {
            self.kind = kind
            self.timescale = timescale
            self.sampleEntry = sampleEntry
            self.width = width
            self.height = height
        }

        var count: Int { sizes.count }
    }

    private let out: BufferedFileWriter
    private(set) var tracks: [Track] = []
    private let mdatHeaderAt: Int64
    private var lastTrack = -1
    static let movieTimescale: UInt32 = 1000

    init(url: URL) throws {
        out = try BufferedFileWriter(url: url)
        // ftyp: isom, 호환 isom/iso2/avc1/mp41
        try out.write(box("ftyp", Array("isom".utf8) + be32(0x200) + Array("isomiso2avc1mp41".utf8)))
        mdatHeaderAt = out.position
        // 크기를 모르니 64비트 largesize로 자리만
        try out.write(be32(1) + Array("mdat".utf8) + be64(0))
    }

    func addTrack(kind: Kind, timescale: UInt32, sampleEntry: [UInt8], width: Int = 0, height: Int = 0) -> Int {
        tracks.append(Track(kind: kind, timescale: timescale, sampleEntry: sampleEntry, width: width, height: height))
        return tracks.count - 1
    }

    /// 코덱 정보는 다 읽고 나서야 알 때가 많아서 나중에 넣는다.
    func setSampleEntry(_ t: Int, _ entry: [UInt8], displayWidth: Int = 0, displayHeight: Int = 0) {
        tracks[t].sampleEntry = entry
        tracks[t].width = displayWidth
        tracks[t].height = displayHeight
    }

    func append(_ t: Int, _ data: ArraySlice<UInt8>, dts: Int64, cts: Int32, sync: Bool) throws {
        let track = tracks[t]
        let offset = out.position
        try out.write(data)
        if lastTrack == t && track.lastEnd == offset, !track.chunkCounts.isEmpty {
            track.chunkCounts[track.chunkCounts.count - 1] += 1
        } else {
            track.chunkOffsets.append(UInt64(offset))
            track.chunkCounts.append(1)
        }
        track.lastEnd = offset + Int64(data.count)
        lastTrack = t
        track.sizes.append(UInt32(data.count))
        track.dts.append(dts)
        track.cts.append(cts)
        if sync {
            track.syncSamples.append(UInt32(track.sizes.count))
        } else {
            track.allSync = false
        }
    }

    /// 샘플을 다 넣은 뒤 표(moov)를 쓰고 닫는다.
    func finish() throws {
        try out.flush()
        let mdatSize = UInt64(out.position - mdatHeaderAt)
        try out.patch(be64(mdatSize), at: mdatHeaderAt + 8)

        // 트랙마다: 미디어 안에서 보이기 시작하는 곳, 다른 트랙과 맞출 표시 시작 시각(초)
        var starts: [Double] = []
        var mediaStarts: [Int64] = []
        var durations: [[UInt32]] = []
        for track in tracks {
            let d = sampleDurations(track)
            durations.append(d)
            let dts0 = track.dts.first ?? 0
            var mediaStart = presentationStart(track) - dts0
            if let edit = track.editMediaTime { mediaStart = max(mediaStart, edit - dts0) }
            mediaStarts.append(mediaStart)
            // 원본 편집 목록이 있으면 그 시각이 영상 시작(0)에 맞춰진다
            let anchor = Double(dts0 + mediaStart - (track.editMediaTime ?? 0)) / Double(track.timescale)
            starts.append(anchor + track.emptyEdit)
        }
        let globalStart = tracks.indices.filter { tracks[$0].count > 0 }.map { starts[$0] }.min() ?? 0

        var traks: [UInt8] = []
        var movieDuration: UInt64 = 0
        for (i, track) in tracks.enumerated() where track.count > 0 {
            let (trak, duration) = buildTrak(track, id: UInt32(i + 1), durations: durations[i],
                                             mediaStart: mediaStarts[i], emptyEdit: starts[i] - globalStart)
            traks += trak
            movieDuration = max(movieDuration, duration)
        }
        let mvhd = fullBox("mvhd", 0, 0,
                           be32(0) + be32(0) + be32(Self.movieTimescale) + be32(UInt32(clamping: movieDuration))
                           + be32(0x0001_0000) + be16(0x0100) + [UInt8](repeating: 0, count: 10)
                           + matrix + [UInt8](repeating: 0, count: 24) + be32(UInt32(tracks.count + 1)))
        try out.write(box("moov", mvhd + traks))
        try out.close()
    }

    private var matrix: [UInt8] {
        be32(0x0001_0000) + be32(0) + be32(0) + be32(0) + be32(0x0001_0000) + be32(0) + be32(0) + be32(0) + be32(0x4000_0000)
    }

    /// 처음 보이는 프레임의 시각(B프레임이 있으면 첫 샘플이 아닐 수 있다): min(dts + cts)
    private func presentationStart(_ t: Track) -> Int64 {
        var best = Int64.max
        for i in 0..<t.count { best = min(best, t.dts[i] + Int64(t.cts[i])) }
        return best == Int64.max ? 0 : best
    }

    private func sampleDurations(_ t: Track) -> [UInt32] {
        if let d = t.explicitDurations, d.count == t.count { return d }
        var d: [UInt32] = []
        d.reserveCapacity(t.count)
        for i in 0..<t.count {
            if i + 1 < t.count {
                d.append(UInt32(clamping: max(1, t.dts[i + 1] - t.dts[i])))
            } else {
                d.append(d.last ?? (t.kind == .audio ? 1024 : t.timescale / 30))
            }
        }
        return d
    }

    /// mediaStart: 미디어 시각(첫 샘플 디코딩 = 0)으로 보이기 시작하는 곳
    private func buildTrak(_ t: Track, id: UInt32, durations: [UInt32], mediaStart: Int64, emptyEdit: Double) -> ([UInt8], UInt64) {
        let mediaDuration = durations.reduce(UInt64(0)) { $0 + UInt64($1) }
        var presentEnd: Int64 = 0
        var acc: Int64 = 0
        for i in 0..<t.count {
            presentEnd = max(presentEnd, acc + Int64(t.cts[i]) + Int64(durations[i]))
            acc += Int64(durations[i])
        }
        let presentDuration = max(0, presentEnd - mediaStart)
        let presentMovie = UInt64(Double(presentDuration) * Double(Self.movieTimescale) / Double(t.timescale))
        let emptyMovie = emptyEdit > 0.0005 ? UInt64((emptyEdit * Double(Self.movieTimescale)).rounded()) : 0
        let trackDuration = emptyMovie + presentMovie

        // edts/elst: 앞의 빈 구간 + 미디어(B프레임 지연만큼 media_time)
        var entries: [UInt8] = []
        var entryCount: UInt32 = 0
        if emptyMovie > 0 {
            entries += be32(UInt32(clamping: emptyMovie)) + be32(UInt32(bitPattern: -1)) + be16(1) + be16(0)
            entryCount += 1
        }
        entries += be32(UInt32(clamping: presentMovie)) + be32(UInt32(clamping: max(0, mediaStart))) + be16(1) + be16(0)
        entryCount += 1
        let edts = box("edts", fullBox("elst", 0, 0, be32(entryCount) + entries))

        let isVideo = t.kind == .video
        let tkhd = fullBox("tkhd", 0, 3,
                           be32(0) + be32(0) + be32(id) + be32(0) + be32(UInt32(clamping: trackDuration)) + be64(0)
                           + be16(0) + be16(isVideo ? 0 : 1) + be16(isVideo ? 0 : 0x0100) + be16(0) + matrix
                           + be32(UInt32(isVideo ? t.width : 0) << 16) + be32(UInt32(isVideo ? t.height : 0) << 16))
        let mdhd: [UInt8]
        if mediaDuration > UInt64(UInt32.max) {
            mdhd = fullBox("mdhd", 1, 0, be64(0) + be64(0) + be32(t.timescale) + be64(mediaDuration) + be16(0x55C4) + be16(0))
        } else {
            mdhd = fullBox("mdhd", 0, 0, be32(0) + be32(0) + be32(t.timescale) + be32(UInt32(mediaDuration)) + be16(0x55C4) + be16(0))
        }
        let handler = isVideo ? "vide" : "soun"
        let hdlr = fullBox("hdlr", 0, 0, be32(0) + Array(handler.utf8) + [UInt8](repeating: 0, count: 12)
                           + Array((isVideo ? "VideoHandler" : "SoundHandler").utf8) + [0])
        let mediaHeader = isVideo ? fullBox("vmhd", 0, 1, [UInt8](repeating: 0, count: 8)) : fullBox("smhd", 0, 0, be32(0))
        let dinf = box("dinf", fullBox("dref", 0, 0, be32(1) + fullBox("url ", 0, 1, [])))
        let stbl = box("stbl", buildSampleTables(t, durations: durations))
        let minf = box("minf", mediaHeader + dinf + stbl)
        let mdia = box("mdia", mdhd + hdlr + minf)
        return (box("trak", tkhd + edts + mdia), trackDuration)
    }

    private func buildSampleTables(_ t: Track, durations: [UInt32]) -> [UInt8] {
        let stsd = fullBox("stsd", 0, 0, be32(1) + t.sampleEntry)

        var stts: [UInt8] = []
        var sttsCount: UInt32 = 0
        var i = 0
        while i < durations.count {
            var j = i + 1
            while j < durations.count && durations[j] == durations[i] { j += 1 }
            stts += be32(UInt32(j - i)) + be32(durations[i])
            sttsCount += 1
            i = j
        }
        var boxes = stsd + fullBox("stts", 0, 0, be32(sttsCount) + stts)

        if t.cts.contains(where: { $0 != 0 }) {
            let signed = t.cts.contains { $0 < 0 }
            var ctts: [UInt8] = []
            var n: UInt32 = 0
            var k = 0
            while k < t.cts.count {
                var j = k + 1
                while j < t.cts.count && t.cts[j] == t.cts[k] { j += 1 }
                ctts += be32(UInt32(j - k)) + be32(UInt32(bitPattern: t.cts[k]))
                n += 1
                k = j
            }
            boxes += fullBox("ctts", signed ? 1 : 0, 0, be32(n) + ctts)
        }
        if !t.allSync {
            var stss = be32(UInt32(t.syncSamples.count))
            stss.reserveCapacity(4 + t.syncSamples.count * 4)
            for s in t.syncSamples { stss += be32(s) }
            boxes += fullBox("stss", 0, 0, stss)
        }
        // stsc: 연속된 같은 개수 묶음
        var stsc: [UInt8] = []
        var stscCount: UInt32 = 0
        var lastCount: UInt32 = 0
        for (c, count) in t.chunkCounts.enumerated() where count != lastCount {
            stsc += be32(UInt32(c + 1)) + be32(count) + be32(1)
            stscCount += 1
            lastCount = count
        }
        boxes += fullBox("stsc", 0, 0, be32(stscCount) + stsc)

        var stsz = be32(0) + be32(UInt32(t.sizes.count))
        stsz.reserveCapacity(8 + t.sizes.count * 4)
        for s in t.sizes { stsz += be32(s) }
        boxes += fullBox("stsz", 0, 0, stsz)

        if t.chunkOffsets.contains(where: { $0 > UInt64(UInt32.max) }) {
            var co = be32(UInt32(t.chunkOffsets.count))
            for o in t.chunkOffsets { co += be64(o) }
            boxes += fullBox("co64", 0, 0, co)
        } else {
            var co = be32(UInt32(t.chunkOffsets.count))
            co.reserveCapacity(4 + t.chunkOffsets.count * 4)
            for o in t.chunkOffsets { co += be32(UInt32(o)) }
            boxes += fullBox("stco", 0, 0, co)
        }
        return boxes
    }

    // MARK: 샘플 설명

    /// H.264 avc1 + avcC (+ pasp)
    static func avc1(config: [UInt8], width: Int, height: Int, sarWidth: Int, sarHeight: Int) -> [UInt8] {
        var p: [UInt8] = [UInt8](repeating: 0, count: 6) + be16(1)
        p += be16(0) + be16(0) + [UInt8](repeating: 0, count: 12)
        p += be16(width) + be16(height) + be32(0x0048_0000) + be32(0x0048_0000) + be32(0) + be16(1)
        var name = [UInt8](repeating: 0, count: 32)
        let label = Array("NAGO DL".utf8)
        name[0] = UInt8(label.count)
        for (i, c) in label.enumerated() { name[i + 1] = c }
        p += name + be16(0x18) + be16(0xFFFF)
        p += box("avcC", config)
        if sarWidth != sarHeight && sarWidth > 0 && sarHeight > 0 {
            p += box("pasp", be32(UInt32(sarWidth)) + be32(UInt32(sarHeight)))
        }
        return box("avc1", p)
    }

    /// AAC mp4a + esds
    static func mp4a(asc: [UInt8], channels: Int, sampleRate: Int) -> [UInt8] {
        var p: [UInt8] = [UInt8](repeating: 0, count: 6) + be16(1)
        p += [UInt8](repeating: 0, count: 8)
        p += be16(max(1, channels)) + be16(16) + be16(0) + be16(0) + be32(UInt32(min(sampleRate, 65535)) << 16)
        func descriptor(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] {
            let n = body.count
            return [tag, 0x80 | UInt8((n >> 21) & 0x7F), 0x80 | UInt8((n >> 14) & 0x7F), 0x80 | UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)] + body
        }
        let decSpecific = descriptor(0x05, asc)
        let decConfig = descriptor(0x04, [0x40, 0x15] + [0, 0, 0] + be32(0) + be32(0) + decSpecific)
        let sl = descriptor(0x06, [0x02])
        let es = descriptor(0x03, be16(0) + [0] + decConfig + sl)
        p += fullBox("esds", 0, 0, es)
        return box("mp4a", p)
    }
}

func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
    be32(UInt32(8 + payload.count)) + Array(type.utf8) + payload
}

func fullBox(_ type: String, _ version: UInt8, _ flags: UInt32, _ payload: [UInt8]) -> [UInt8] {
    box(type, [version, UInt8((flags >> 16) & 0xFF), UInt8((flags >> 8) & 0xFF), UInt8(flags & 0xFF)] + payload)
}
