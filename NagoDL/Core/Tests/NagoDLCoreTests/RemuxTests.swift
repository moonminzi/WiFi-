import XCTest
@testable import NagoDLCore

/// ffmpeg로 만든 HLS를 MP4로 옮긴 뒤, 디코딩한 프레임 해시가 원본과 같은지 본다(다시 인코딩하지 않으니 같아야 한다).
/// ffmpeg가 없으면 건너뛴다.
final class RemuxTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        guard Self.which("ffmpeg") != nil, Self.which("ffprobe") != nil else { throw XCTSkip("ffmpeg 없음") }
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("remux-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    static func which(_ tool: String) -> String? {
        for p in ["/usr/bin/", "/usr/local/bin/", "/opt/homebrew/bin/"] where FileManager.default.isExecutableFile(atPath: p + tool) {
            return p + tool
        }
        return nil
    }

    @discardableResult
    func run(_ args: [String], check: Bool = true) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.which(args[0]) ?? args[0])
        p.arguments = Array(args.dropFirst())
        p.currentDirectoryURL = dir
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        if check && p.terminationStatus != 0 { XCTFail("\(args.joined(separator: " ")) 실패:\n\(text.suffix(2000))") }
        return text
    }

    /// 스트림별 (크기, 해시) 목록
    func frames(_ input: [String], stream: String) throws -> [String] {
        let text = try run(["ffmpeg", "-v", "error"] + input + ["-map", "0:\(stream)", "-fps_mode", "passthrough", "-f", "framemd5", "-"])
        return text.split(separator: "\n").filter { !$0.hasPrefix("#") }.map { line in
            let cols = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return cols.suffix(2).joined(separator: ",")
        }
    }

    func segments(_ playlist: String) throws -> [TSRemuxer.Input] {
        let url = dir.appendingPathComponent(playlist)
        guard case .media(let media) = try M3U8.parse(Data(contentsOf: url), baseURL: url) else {
            XCTFail("미디어 목록 아님")
            return []
        }
        return media.segments.map { TSRemuxer.Input(url: $0.url, discontinuity: $0.discontinuity) }
    }

    func assertDecodesCleanly(_ file: URL, file f: StaticString = #filePath, line: UInt = #line) throws {
        let errors = try run(["ffmpeg", "-v", "error", "-i", file.path, "-f", "null", "-"], check: false)
        XCTAssertEqual(errors.trimmingCharacters(in: .whitespacesAndNewlines), "", "디코딩 오류", file: f, line: line)
    }

    /// 첫 오디오 프레임 시각 - 첫 영상 프레임 시각(싱크)
    func avOffset(_ input: [String]) throws -> Double {
        func first(_ s: String) throws -> Double {
            let text = try run(["ffprobe", "-v", "error"] + Array(input.dropFirst()) + ["-select_streams", s,
                                "-show_entries", "frame=pts_time", "-of", "csv=p=0", "-read_intervals", "%+#1"])
            return Double(text.split(separator: "\n").first?.trimmingCharacters(in: CharacterSet(charactersIn: ", ")) ?? "") ?? .nan
        }
        return try first("a") - first("v")
    }

    func probe(_ file: URL) throws -> [[String: Any]] {
        let text = try run(["ffprobe", "-v", "error", "-show_streams", "-of", "json", file.path])
        let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        return obj?["streams"] as? [[String: Any]] ?? []
    }

    // MARK: TS

    func makeTSHLS(_ name: String, seconds: Int = 9, extraVideo: [String] = [], size: String = "320x240") throws {
        try run(["ffmpeg", "-v", "error", "-y",
                 "-f", "lavfi", "-i", "testsrc2=size=\(size):rate=25",
                 "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=44100",
                 "-t", "\(seconds)"] + extraVideo + [
                 "-c:v", "libx264", "-preset", "veryfast", "-bf", "2", "-g", "50", "-pix_fmt", "yuv420p",
                 "-c:a", "aac", "-b:a", "96k",
                 "-f", "hls", "-hls_time", "3", "-hls_playlist_type", "vod",
                 "-hls_segment_filename", "\(name)_%03d.ts", "\(name).m3u8"])
    }

    func testTSWithBFramesMatchesSourceFrameByFrame() throws {
        try makeTSHLS("a")
        let segs = try segments("a.m3u8")
        XCTAssertEqual(segs.count, 3)
        let out = dir.appendingPathComponent("a.mp4")
        let r = try TSRemuxer.remux(main: segs, output: out)
        XCTAssertTrue(r.hasVideo && r.hasAudio)
        XCTAssertEqual(r.width, 320)
        XCTAssertEqual(r.height, 240)
        try assertDecodesCleanly(out)
        let source = ["-i", "concat:" + segs.map(\.url.path).joined(separator: "|")]
        XCTAssertEqual(try frames(["-i", out.path], stream: "v"), try frames(source, stream: "v"))
        XCTAssertEqual(try frames(["-i", out.path], stream: "a"), try frames(source, stream: "a"))
        XCTAssertGreaterThan(try frames(["-i", out.path], stream: "v").count, 200)
        XCTAssertEqual(try avOffset(["-i", out.path]), try avOffset(source), accuracy: 0.002, "싱크가 달라짐")
        let streams = try probe(out)
        XCTAssertEqual(streams.compactMap { $0["codec_name"] as? String }.sorted(), ["aac", "h264"])
        // 길이: 9초 안팎
        let duration = Double(streams.first { $0["codec_name"] as? String == "h264" }?["duration"] as? String ?? "0") ?? 0
        XCTAssertEqual(duration, 9, accuracy: 0.2)
    }

    func testDiscontinuityKeepsTimestampsMonotonic() throws {
        try makeTSHLS("p", seconds: 6)
        // 두 번째 영상은 시각이 100초부터 시작(광고가 끼어든 것처럼)
        try run(["ffmpeg", "-v", "error", "-y",
                 "-f", "lavfi", "-i", "testsrc=size=320x240:rate=25",
                 "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100",
                 "-t", "6", "-output_ts_offset", "100",
                 "-c:v", "libx264", "-preset", "veryfast", "-bf", "2", "-g", "50", "-pix_fmt", "yuv420p",
                 "-c:a", "aac", "-b:a", "96k",
                 "-f", "hls", "-hls_time", "3", "-hls_playlist_type", "vod",
                 "-hls_segment_filename", "q_%03d.ts", "q.m3u8"])
        var inputs = try segments("p.m3u8")
        var second = try segments("q.m3u8")
        second[0].discontinuity = true
        inputs += second
        let out = dir.appendingPathComponent("d.mp4")
        _ = try TSRemuxer.remux(main: inputs, output: out)
        try assertDecodesCleanly(out)
        let streams = try probe(out)
        let video = streams.first { $0["codec_name"] as? String == "h264" }
        let duration = Double(video?["duration"] as? String ?? "0") ?? 0
        XCTAssertEqual(duration, 12, accuracy: 0.3, "끊김을 이어 붙이지 못함")
        // DTS가 항상 늘어나는지
        let text = try run(["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "packet=dts", "-of", "csv=p=0", out.path])
        let dts = text.split(separator: "\n").compactMap { Int($0) }
        XCTAssertGreaterThan(dts.count, 290)
        XCTAssertEqual(dts, dts.sorted())
        XCTAssertEqual(Set(dts).count, dts.count)
    }

    func testAnamorphicKeepsAspectRatio() throws {
        try makeTSHLS("s", seconds: 3, extraVideo: ["-vf", "setsar=4/3"])
        let out = dir.appendingPathComponent("s.mp4")
        _ = try TSRemuxer.remux(main: try segments("s.m3u8"), output: out)
        let video = try probe(out).first { $0["codec_name"] as? String == "h264" }
        XCTAssertEqual(video?["sample_aspect_ratio"] as? String, "4:3")
    }

    func testOddSizeAndHighProfile() throws {
        try makeTSHLS("o", seconds: 3, extraVideo: ["-profile:v", "high"], size: "318x178")
        let out = dir.appendingPathComponent("o.mp4")
        let r = try TSRemuxer.remux(main: try segments("o.m3u8"), output: out)
        XCTAssertEqual(r.width, 318)
        XCTAssertEqual(r.height, 178)
        try assertDecodesCleanly(out)
    }

    func testHEVCIsReportedUnsupported() throws {
        try run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=25", "-t", "2",
                 "-c:v", "libx265", "-x265-params", "log-level=error", "-f", "hls", "-hls_time", "2", "-hls_playlist_type", "vod",
                 "-hls_segment_filename", "h_%03d.ts", "h.m3u8"])
        XCTAssertThrowsError(try TSRemuxer.remux(main: try segments("h.m3u8"), output: dir.appendingPathComponent("h.mp4"))) {
            XCTAssertEqual($0 as? RemuxError, .unsupportedCodec("HEVC"))
        }
    }

    func testSeparateAudioRenditionInTS() throws {
        // 영상만 있는 TS + 오디오만 있는 TS
        try run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=30", "-t", "6",
                 "-c:v", "libx264", "-preset", "veryfast", "-bf", "2", "-g", "60", "-pix_fmt", "yuv420p",
                 "-f", "hls", "-hls_time", "2", "-hls_playlist_type", "vod", "-hls_segment_filename", "v_%03d.ts", "v.m3u8"])
        try run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=660:sample_rate=48000", "-t", "6",
                 "-c:a", "aac", "-b:a", "128k",
                 "-f", "hls", "-hls_time", "2", "-hls_playlist_type", "vod", "-hls_segment_filename", "au_%03d.ts", "au.m3u8"])
        let video = try segments("v.m3u8")
        let audio = try segments("au.m3u8")
        let out = dir.appendingPathComponent("va.mp4")
        let r = try TSRemuxer.remux(main: video, audio: audio, output: out)
        XCTAssertTrue(r.hasVideo && r.hasAudio)
        try assertDecodesCleanly(out)
        XCTAssertEqual(try frames(["-i", out.path], stream: "v"),
                       try frames(["-i", "concat:" + video.map(\.url.path).joined(separator: "|")], stream: "v"))
        XCTAssertEqual(try frames(["-i", out.path], stream: "a"),
                       try frames(["-i", "concat:" + audio.map(\.url.path).joined(separator: "|")], stream: "a"))
    }

    func testPackedAudioWithID3Timestamp() throws {
        try run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=500:sample_rate=44100", "-t", "4",
                 "-c:a", "aac", "-b:a", "96k", "-f", "adts", "raw.aac"])
        let adts = try Data(contentsOf: dir.appendingPathComponent("raw.aac"))
        // ID3v2.4 + PRIV(com.apple.streaming.transportStreamTimestamp, 90k 시각 = 10초)
        let owner = Array("com.apple.streaming.transportStreamTimestamp".utf8) + [0]
        let ts = be64(900_000)
        let frameBody = owner + ts
        let frame = Array("PRIV".utf8) + be32(UInt32(frameBody.count)) + [0, 0] + frameBody
        func synchsafe(_ n: Int) -> [UInt8] { [UInt8((n >> 21) & 0x7F), UInt8((n >> 14) & 0x7F), UInt8((n >> 7) & 0x7F), UInt8(n & 0x7F)] }
        let id3 = Array("ID3".utf8) + [4, 0, 0] + synchsafe(frame.count) + frame
        let seg = dir.appendingPathComponent("p0.aac")
        try Data(id3 + [UInt8](adts)).write(to: seg)
        let out = dir.appendingPathComponent("p.m4a")
        let r = try TSRemuxer.remux(main: [TSRemuxer.Input(url: seg)], mainIsPackedAudio: true, output: out)
        XCTAssertFalse(r.hasVideo)
        XCTAssertTrue(r.hasAudio)
        try assertDecodesCleanly(out)
        XCTAssertEqual(try frames(["-i", out.path], stream: "a"), try frames(["-i", dir.appendingPathComponent("raw.aac").path], stream: "a"))
    }

    // MARK: fMP4

    func testFMP4MatchesSource() throws {
        try run(["ffmpeg", "-v", "error", "-y",
                 "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=25",
                 "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000", "-t", "8",
                 "-c:v", "libx264", "-preset", "veryfast", "-bf", "2", "-g", "50", "-pix_fmt", "yuv420p",
                 "-c:a", "aac", "-b:a", "96k",
                 "-f", "hls", "-hls_time", "2", "-hls_playlist_type", "vod", "-hls_segment_type", "fmp4",
                 "-hls_fmp4_init_filename", "f_init.mp4", "-hls_segment_filename", "f_%03d.m4s", "f.m3u8"])
        let url = dir.appendingPathComponent("f.m3u8")
        guard case .media(let media) = try M3U8.parse(Data(contentsOf: url), baseURL: url) else { return XCTFail() }
        let job = try HLSLoader.describe(media)
        XCTAssertEqual(job.0, .fmp4)
        let initURL = try XCTUnwrap(job.1?.url)
        let out = dir.appendingPathComponent("f.mp4")
        let r = try FMP4Remuxer.remux(initSegment: initURL, parts: media.segments.map(\.url), output: out)
        XCTAssertTrue(r.hasVideo && r.hasAudio)
        try assertDecodesCleanly(out)
        // 원본: init + 조각을 이어 붙인 것
        let joined = dir.appendingPathComponent("joined.mp4")
        var all = try Data(contentsOf: initURL)
        for s in media.segments { all += try Data(contentsOf: s.url) }
        try all.write(to: joined)
        XCTAssertEqual(try frames(["-i", out.path], stream: "v"), try frames(["-i", joined.path], stream: "v"))
        XCTAssertEqual(try frames(["-i", out.path], stream: "a"), try frames(["-i", joined.path], stream: "a"))
        XCTAssertEqual(try avOffset(["-i", out.path]), try avOffset(["-i", joined.path]), accuracy: 0.002, "싱크가 달라짐")
        // 조각 없는 보통 MP4가 됐는지(moof 없음)
        let bytes = try [UInt8](Data(contentsOf: out))
        XCTAssertFalse(FMP4Remuxer.boxes(bytes, 0, bytes.count).contains { $0.type == "moof" })
    }

    func testFMP4SeparateAudioIsMerged() throws {
        try run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x240:rate=30", "-t", "6",
                 "-c:v", "libx264", "-preset", "veryfast", "-bf", "2", "-g", "60", "-pix_fmt", "yuv420p",
                 "-f", "hls", "-hls_time", "2", "-hls_playlist_type", "vod", "-hls_segment_type", "fmp4",
                 "-hls_fmp4_init_filename", "fv_init.mp4", "-hls_segment_filename", "fv_%03d.m4s", "fv.m3u8"])
        try run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=330:sample_rate=48000", "-t", "6",
                 "-c:a", "aac", "-b:a", "128k",
                 "-f", "hls", "-hls_time", "2", "-hls_playlist_type", "vod", "-hls_segment_type", "fmp4",
                 "-hls_fmp4_init_filename", "fa_init.mp4", "-hls_segment_filename", "fa_%03d.m4s", "fa.m3u8"])
        func parts(_ name: String) throws -> [URL] {
            let url = dir.appendingPathComponent(name)
            guard case .media(let m) = try M3U8.parse(Data(contentsOf: url), baseURL: url) else { return [] }
            return m.segments.map(\.url)
        }
        let out = dir.appendingPathComponent("fva.mp4")
        let r = try FMP4Remuxer.remux(initSegment: dir.appendingPathComponent("fv_init.mp4"), parts: try parts("fv.m3u8"),
                                      audioInit: dir.appendingPathComponent("fa_init.mp4"), audioParts: try parts("fa.m3u8"),
                                      output: out)
        XCTAssertTrue(r.hasVideo && r.hasAudio)
        try assertDecodesCleanly(out)
        let streams = try probe(out)
        XCTAssertEqual(streams.compactMap { $0["codec_name"] as? String }.sorted(), ["aac", "h264"])
    }

    // MARK: 재생 목록

    func testMasterPlaylistParsing() throws {
        let text = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",DEFAULT=YES,URI="audio/en.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.4d401e,mp4a.40.2",AUDIO="aud"
        360p/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=5000000,AVERAGE-BANDWIDTH=4500000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2",AUDIO="aud"
        https://cdn.example.com/1080p/index.m3u8?token=a,b
        #EXT-X-STREAM-INF:BANDWIDTH=64000,CODECS="mp4a.40.2"
        audio-only.m3u8
        """
        let base = URL(string: "https://example.com/hls/master.m3u8")!
        guard case .master(let variants, let renditions) = try M3U8.parse(text, baseURL: base) else { return XCTFail() }
        XCTAssertEqual(variants.count, 3)
        XCTAssertEqual(variants[0].url.absoluteString, "https://example.com/hls/360p/index.m3u8")
        XCTAssertEqual(variants[1].height, 1080)
        XCTAssertEqual(variants[1].label, "1080p · 4.5 Mbps")
        XCTAssertEqual(variants[1].url.query, "token=a,b")
        XCTAssertTrue(variants[2].isAudioOnly)
        XCTAssertEqual(renditions.first?.url?.absoluteString, "https://example.com/hls/audio/en.m3u8")
        XCTAssertEqual(renditions.first?.isDefault, true)
    }

    func testMediaPlaylistByteRangeKeyAndLive() throws {
        let text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-MAP:URI="init.mp4",BYTERANGE="700@0"
        #EXTINF:6.0,
        #EXT-X-BYTERANGE:1000@700
        all.mp4
        #EXTINF:6.0,
        #EXT-X-BYTERANGE:2000
        all.mp4
        #EXT-X-DISCONTINUITY
        #EXTINF:4.5,
        #EXT-X-BYTERANGE:1500
        all.mp4
        #EXT-X-ENDLIST
        """
        let base = URL(string: "https://e.com/v/play.m3u8")!
        guard case .media(let m) = try M3U8.parse(text, baseURL: base) else { return XCTFail() }
        XCTAssertEqual(m.segments.map(\.rangeOffset), [700, 1700, 3700])
        XCTAssertEqual(m.segments.map(\.rangeLength), [1000, 2000, 1500])
        XCTAssertEqual(m.segments.map(\.discontinuity), [false, false, true])
        XCTAssertEqual(m.segments.first?.mapRangeLength, 700)
        XCTAssertEqual(m.duration, 16.5)
        XCTAssertTrue(m.endList)
        let described = try HLSLoader.describe(m)
        XCTAssertEqual(described.0, .fmp4)
        XCTAssertEqual(described.1?.rangeLength, 700)

        let enc = "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"k\"\n#EXTINF:4,\na.ts\n#EXT-X-ENDLIST\n"
        guard case .media(let e) = try M3U8.parse(enc, baseURL: base) else { return XCTFail() }
        XCTAssertThrowsError(try HLSLoader.describe(e)) { XCTAssertEqual($0 as? HLSError, .encrypted("AES-128")) }

        let live = "#EXTM3U\n#EXTINF:4,\na.ts\n"
        guard case .media(let l) = try M3U8.parse(live, baseURL: base) else { return XCTFail() }
        XCTAssertThrowsError(try HLSLoader.describe(l)) { XCTAssertEqual($0 as? HLSError, .live) }
    }
}
