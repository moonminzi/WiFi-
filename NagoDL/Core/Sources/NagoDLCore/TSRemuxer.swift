import Foundation

public enum RemuxError: Error, LocalizedError, Equatable {
    case noStreams
    case unsupportedCodec(String)
    case noKeyframe

    public var errorDescription: String? {
        switch self {
        case .noStreams: return "영상/음성 스트림이 없어요"
        case .unsupportedCodec(let c): return "지원하지 않는 코덱(\(c))"
        case .noKeyframe: return "키프레임이 없어요"
        }
    }
}

/// HLS 조각(MPEG-TS, ADTS)을 다시 인코딩하지 않고 MP4로 옮긴다. H.264 + AAC.
public final class TSRemuxer {
    public struct Input: Sendable {
        public var url: URL
        public var discontinuity: Bool

        public init(url: URL, discontinuity: Bool = false) {
            self.url = url
            self.discontinuity = discontinuity
        }
    }

    public struct Result: Sendable, Equatable {
        public var hasVideo: Bool
        public var hasAudio: Bool
        public var videoFrames: Int
        public var audioFrames: Int
        public var width: Int
        public var height: Int
    }

    static let wrap: Int64 = 1 << 33
    static let clock: Int64 = 90_000

    private let writer: MP4Writer
    private var videoTrack: Int?
    private var audioTrack: Int?

    // 영상
    private var sps: [UInt8]?
    private var ppsList: [[UInt8]] = []
    private var spsInfo: H264.SPSInfo?
    private var sawKeyframe = false
    private var lastVideoDTS: Int64?
    private var lastVideoDuration: Int64 = 3000
    private var videoFrames = 0

    // 음성
    private var adts: ADTS.Header?
    private var audioPositions: [Int64] = []
    private var audioDurations: [UInt32] = []
    private var audioEnd: Int64?        // 다음 프레임이 놓일 자리(샘플 단위)
    private var lastAudioPTS: Int64?    // 90k

    private init(output: URL) throws {
        writer = try MP4Writer(url: output)
    }

    /// main: 영상(+음성) TS 조각들. audio: 따로 있는 음성 조각(TS 또는 ADTS).
    public static func remux(main: [Input], mainIsPackedAudio: Bool = false, audio: [Input] = [], audioIsPacked: Bool = false,
                             output: URL, progress: ((Double) -> Void)? = nil) throws -> Result {
        let r = try TSRemuxer(output: output)
        let total = Double(max(1, main.count + audio.count))
        var done = 0.0

        var mainTimeline = Timeline()
        for input in main {
            let data = try Data(contentsOf: input.url, options: .alwaysMapped)
            let samples = mainIsPackedAudio ? try r.readPackedAudio(data) : try r.demux(data, wantVideo: true, wantAudio: true)
            try r.write(samples, timeline: &mainTimeline, discontinuity: input.discontinuity)
            done += 1
            progress?(done / total)
        }
        var audioTimeline = Timeline()
        for input in audio {
            let data = try Data(contentsOf: input.url, options: .alwaysMapped)
            let samples = audioIsPacked ? try r.readPackedAudio(data) : try r.demux(data, wantVideo: false, wantAudio: true)
            try r.write(samples, timeline: &audioTimeline, discontinuity: input.discontinuity)
            done += 1
            progress?(done / total)
        }
        return try r.finish()
    }

    // MARK: 조각 하나 읽기

    struct Sample {
        enum Kind { case video, audio }
        var kind: Kind
        /// 90k, 33비트 그대로(아직 펼치지 않음)
        var pts: Int64
        var dts: Int64
        var data: [UInt8]
        var keyframe: Bool
    }

    private var pendingAudio: [UInt8] = []
    private var pendingAudioPTS: Int64?

    private func demux(_ data: Data, wantVideo: Bool, wantAudio: Bool) throws -> [Sample] {
        let demuxer = TSDemuxer()
        var out: [Sample] = []
        var lastVideoPTS: Int64?
        var error: RemuxError?
        demuxer.onPES = { [self] _, type, pes in
            switch type {
            case 0x1B where wantVideo:
                guard let pts = pes.pts ?? lastVideoPTS.map({ $0 + self.lastVideoDuration }) else { return }
                lastVideoPTS = pts
                if let s = self.videoSample(pes.payload, pts: pts, dts: pes.dts ?? pts) { out.append(s) }
            case 0x0F where wantAudio:
                out += self.audioSamples(pes.payload, pts: pes.pts)
            case 0x24 where wantVideo:
                error = .unsupportedCodec("HEVC")
            case 0x03, 0x04:
                if wantAudio { error = .unsupportedCodec("MP3") }
            case 0x81, 0x87:
                if wantAudio { error = .unsupportedCodec("AC-3") }
            case 0xDB, 0xCF, 0xC1, 0xC2:
                error = .unsupportedCodec("암호화")
            default:
                break
            }
        }
        data.withUnsafeBytes { demuxer.feed($0) }
        demuxer.flush()
        if let error { throw error }
        if demuxer.streams.isEmpty { throw RemuxError.noStreams }
        // 조각 끝에 남은 반쪽 ADTS는 버린다(다음 조각은 새 PES로 시작)
        pendingAudio.removeAll()
        pendingAudioPTS = nil
        return out
    }

    /// Annex B 접근 단위 → 길이 붙은 NAL들(SPS/PPS/AUD는 빼서 avcC로)
    private func videoSample(_ payload: [UInt8], pts: Int64, dts: Int64) -> Sample? {
        var data: [UInt8] = []
        data.reserveCapacity(payload.count + 16)
        var key = false
        for r in H264.nalRanges(payload) {
            let type = payload[r.lowerBound] & 0x1F
            switch type {
            case 7:
                let nal = Array(payload[r])
                if sps == nil {
                    sps = nal
                    spsInfo = H264.parseSPS(nal[...])
                }
            case 8:
                let nal = Array(payload[r])
                if !ppsList.contains(nal) && ppsList.count < 32 { ppsList.append(nal) }
            case 9, 12:
                break
            default:
                if type == 5 { key = true }
                data += be32(UInt32(r.count))
                data += payload[r]
            }
        }
        guard !data.isEmpty else { return nil }
        return Sample(kind: .video, pts: pts, dts: dts, data: data, keyframe: key)
    }

    /// PES 안의 ADTS 프레임들. 프레임이 PES 경계에 걸치면 다음 PES와 이어 붙인다.
    private func audioSamples(_ payload: [UInt8], pts: Int64?) -> [Sample] {
        var buf = pendingAudio
        let carried = buf.count
        buf += payload
        var out: [Sample] = []
        var i = 0
        var nextPTS = pendingAudioPTS ?? pts
        var usedPESpts = carried == 0
        buf.withUnsafeBytes { b in
            while i + 7 <= b.count {
                guard let h = ADTS.parse(b, at: i) else {
                    i += 1
                    continue
                }
                guard i + h.frameLength <= b.count else { break }
                if adts == nil { adts = h }
                // 이 PES 안에서 시작하는 첫 프레임이 PES의 PTS를 가진다
                if !usedPESpts && i >= carried {
                    usedPESpts = true
                    if let pts { nextPTS = pts }
                }
                if let ts = nextPTS {
                    out.append(Sample(kind: .audio, pts: ts, dts: ts,
                                      data: Array(b[(i + h.headerLength)..<(i + h.frameLength)]), keyframe: true))
                    nextPTS = ts + 1024 * Self.clock / Int64(max(1, h.sampleRate))
                }
                i += h.frameLength
            }
        }
        pendingAudio = i < buf.count ? Array(buf[i...]) : []
        pendingAudioPTS = pendingAudio.isEmpty ? nil : nextPTS
        // 덜 온 프레임이 이 PES 안에서 시작했다면 그 프레임이 PES의 PTS를 가진다
        if !usedPESpts, let pts, i >= carried, !pendingAudio.isEmpty { pendingAudioPTS = pts }
        return out
    }

    /// 오디오만 담긴 HLS 조각(.aac): ID3(시각) + ADTS 프레임들
    private func readPackedAudio(_ data: Data) throws -> [Sample] {
        let bytes = [UInt8](data)
        var i = 0
        var ts: Int64 = lastAudioPTS.map { $0 + 1024 * Self.clock / Int64(adts?.sampleRate ?? 44100) } ?? 0
        while i + 10 <= bytes.count, bytes[i] == 0x49, bytes[i + 1] == 0x44, bytes[i + 2] == 0x33 {
            let size = Int(bytes[i + 6] & 0x7F) << 21 | Int(bytes[i + 7] & 0x7F) << 14 | Int(bytes[i + 8] & 0x7F) << 7 | Int(bytes[i + 9] & 0x7F)
            let end = min(bytes.count, i + 10 + size)
            if let t = Self.id3Timestamp(Array(bytes[(i + 10)..<end])) { ts = t }
            i = end
        }
        pendingAudio.removeAll()
        pendingAudioPTS = nil
        return audioSamples(Array(bytes[i...]), pts: ts)
    }

    /// PRIV com.apple.streaming.transportStreamTimestamp
    static func id3Timestamp(_ frames: [UInt8]) -> Int64? {
        let owner = Array("com.apple.streaming.transportStreamTimestamp".utf8)
        var i = 0
        while i + 10 <= frames.count {
            let id = String(decoding: frames[i..<(i + 4)], as: UTF8.self)
            let size = Int(frames[i + 4]) << 24 | Int(frames[i + 5]) << 16 | Int(frames[i + 6]) << 8 | Int(frames[i + 7])
            let body = i + 10
            guard size > 0, body + size <= frames.count else { return nil }
            if id == "PRIV", size >= owner.count + 9, Array(frames[body..<(body + owner.count)]) == owner, frames[body + owner.count] == 0 {
                let p = body + owner.count + 1
                var v: Int64 = 0
                for k in 0..<8 { v = v << 8 | Int64(frames[p + k]) }
                return v & (Self.wrap - 1)
            }
            i = body + size
        }
        return nil
    }

    // MARK: 시각 맞추기 + 쓰기

    /// 트랙 묶음(본 조각 또는 따로 있는 오디오)의 시각 상태
    struct Timeline {
        var lastRaw: Int64?
        var offset: Int64 = 0
        /// 다음 조각이 시작돼야 할 출력 시각(90k)
        var expected: Int64?
    }

    private func unwrap(_ raw: Int64, near ref: Int64?) -> Int64 {
        guard let ref else { return raw }
        var v = raw + (ref >= 0 ? ref / Self.wrap : (ref - Self.wrap + 1) / Self.wrap) * Self.wrap
        if v - ref > Self.wrap / 2 { v -= Self.wrap } else if ref - v > Self.wrap / 2 { v += Self.wrap }
        return v
    }

    private func write(_ input: [Sample], timeline: inout Timeline, discontinuity: Bool) throws {
        guard !input.isEmpty else { return }
        // 33비트 시각을 펼친다(조각 안에서 돌아가도 이어지게)
        var samples = input
        var ref = timeline.lastRaw
        for k in samples.indices {
            let d = unwrap(samples[k].dts, near: ref)
            let p = unwrap(samples[k].pts, near: d)
            samples[k].dts = d
            samples[k].pts = p
            ref = d
        }
        timeline.lastRaw = samples.map(\.dts).max()
        let segMin = samples.map(\.dts).min() ?? 0
        if let expected = timeline.expected {
            let start = segMin + timeline.offset
            // 끊김 표시가 있거나 시각이 크게 튀면 앞 조각 끝에 바로 붙인다
            if discontinuity || start < expected - Self.clock || start > expected + 10 * Self.clock {
                timeline.offset = expected - segMin
            }
        }
        // 시각순으로 섞어서(영상/음성이 파일 안에서 번갈아 놓이게)
        samples.sort { $0.dts < $1.dts }
        var end: Int64 = timeline.expected ?? 0
        for s in samples {
            let dts = s.dts + timeline.offset
            let pts = s.pts + timeline.offset
            switch s.kind {
            case .video:
                try writeVideo(s, dts: dts, pts: pts)
                end = max(end, dts + lastVideoDuration)
            case .audio:
                try writeAudio(s, pts: pts)
                end = max(end, pts + 1024 * Self.clock / Int64(adts?.sampleRate ?? 44100))
            }
        }
        timeline.expected = end
    }

    private func writeVideo(_ s: Sample, dts rawDTS: Int64, pts: Int64) throws {
        if !sawKeyframe {
            // 첫 키프레임 전 프레임은 디코딩할 수 없다
            guard s.keyframe else { return }
            sawKeyframe = true
        }
        if videoTrack == nil {
            videoTrack = writer.addTrack(kind: .video, timescale: UInt32(Self.clock), sampleEntry: [])
        }
        var dts = min(rawDTS, pts)
        if let last = lastVideoDTS {
            if dts <= last { dts = last + 1 }
            lastVideoDuration = max(1, min(dts - last, Self.clock))
        }
        lastVideoDTS = dts
        let cts = Int32(clamping: max(0, pts - dts))
        try writer.append(videoTrack!, s.data[...], dts: dts, cts: cts, sync: s.keyframe)
        videoFrames += 1
    }

    private func writeAudio(_ s: Sample, pts: Int64) throws {
        guard let h = adts else { return }
        if audioTrack == nil {
            audioTrack = writer.addTrack(kind: .audio, timescale: UInt32(h.sampleRate), sampleEntry: [])
        }
        let rate = Int64(h.sampleRate)
        let position = (pts * rate + Self.clock / 2) / Self.clock
        if let end = audioEnd, !audioDurations.isEmpty {
            let gap = position - end
            if gap > 512 && gap < rate * 60 {
                // 빈 구간: 앞 프레임을 그만큼 길게
                audioDurations[audioDurations.count - 1] += UInt32(gap)
                audioEnd = end + gap
            }
        }
        let at = audioEnd ?? position
        audioPositions.append(at)
        audioDurations.append(1024)
        audioEnd = at + 1024
        lastAudioPTS = pts
        try writer.append(audioTrack!, s.data[...], dts: at, cts: 0, sync: true)
    }

    private func finish() throws -> Result {
        guard videoTrack != nil || audioTrack != nil else {
            throw sps == nil && adts == nil ? RemuxError.noStreams : RemuxError.noKeyframe
        }
        var width = 0, height = 0
        if let v = videoTrack {
            guard let sps else { throw RemuxError.unsupportedCodec("SPS 없음") }
            let info = spsInfo
            width = info?.width ?? 0
            height = info?.height ?? 0
            let sarW = info?.sarWidth ?? 1
            let sarH = info?.sarHeight ?? 1
            let config = H264.avcConfiguration(sps: sps, pps: ppsList)
            writer.setSampleEntry(v, MP4Writer.avc1(config: config, width: width, height: height, sarWidth: sarW, sarHeight: sarH),
                                  displayWidth: sarH > 0 ? width * sarW / sarH : width, displayHeight: height)
        }
        if let a = audioTrack, let h = adts {
            writer.setSampleEntry(a, MP4Writer.mp4a(asc: h.audioSpecificConfig, channels: h.channels, sampleRate: h.sampleRate))
            writer.tracks[a].explicitDurations = audioDurations
        }
        try writer.finish()
        return Result(hasVideo: videoTrack != nil, hasAudio: audioTrack != nil, videoFrames: videoFrames,
                      audioFrames: audioDurations.count, width: width, height: height)
    }
}
