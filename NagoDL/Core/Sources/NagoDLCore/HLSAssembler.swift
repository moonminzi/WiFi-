import Foundation

/// 합친 결과 파일
public struct AssembledOutput: Sendable {
    public var url: URL
    public var fileExtension: String
    /// 사용자에게 알릴 말(예: 코덱을 몰라서 .ts로 저장)
    public var note: String?

    public init(url: URL, fileExtension: String, note: String? = nil) {
        self.url = url
        self.fileExtension = fileExtension
        self.note = note
    }
}

/// HLS 조각을 파일 하나로 만드는 방법
public protocol HLSAssembling: Sendable {
    func assemble(job: HLSJob, id: UUID, paths: EnginePaths, workDir: URL,
                  progress: @escaping @Sendable (Double) -> Void) throws -> AssembledOutput
}

/// 기본: TS/ADTS는 직접 MP4로 옮기고, fMP4는 조각을 풀어 보통 MP4로 다시 쓴다.
/// 모르는 코덱이면 원본 조각을 이어 붙여 .ts로 남긴다(VLC 등에서 재생).
public struct DefaultHLSAssembler: HLSAssembling {
    public init() {}

    public func assemble(job: HLSJob, id: UUID, paths: EnginePaths, workDir: URL,
                         progress: @escaping @Sendable (Double) -> Void) throws -> AssembledOutput {
        let fm = FileManager.default
        let out = workDir.appendingPathComponent("out.mp4")
        try? fm.removeItem(at: out)
        let main = job.parts.indices.map {
            TSRemuxer.Input(url: paths.hlsPartURL(id, track: .main, index: $0), discontinuity: job.parts[$0].discontinuity)
        }
        let audio = job.audioParts.indices.map {
            TSRemuxer.Input(url: paths.hlsPartURL(id, track: .audio, index: $0), discontinuity: job.audioParts[$0].discontinuity)
        }
        switch job.container {
        case .ts, .packedAudio:
            var audioInputs: [TSRemuxer.Input] = []
            var note: String?
            switch job.audioContainer {
            case .ts?, .packedAudio?: audioInputs = audio
            case .fmp4?: note = "따로 있는 오디오 형식을 합치지 못해 영상만 저장했어요"
            case nil: break
            }
            do {
                let r = try TSRemuxer.remux(main: main, mainIsPackedAudio: job.container == .packedAudio,
                                            audio: audioInputs, audioIsPacked: job.audioContainer == .packedAudio,
                                            output: out, progress: progress)
                return AssembledOutput(url: out, fileExtension: r.hasVideo ? "mp4" : "m4a", note: note)
            } catch let error as RemuxError {
                try? fm.removeItem(at: out)
                let raw = workDir.appendingPathComponent("out.raw")
                try concatenate(main.map(\.url), to: raw, progress: progress)
                return AssembledOutput(url: raw, fileExtension: job.container == .packedAudio ? "aac" : "ts",
                                       note: "MP4로 못 바꿔서(\(error.localizedDescription)) 원본 형식으로 저장했어요 — VLC 같은 앱에서 재생돼요")
            }
        case .fmp4:
            let initURL = job.initSegment != nil ? paths.hlsPartURL(id, track: .main, index: -1) : nil
            let audioInit = job.audioInit != nil ? paths.hlsPartURL(id, track: .audio, index: -1) : nil
            do {
                let r = try FMP4Remuxer.remux(initSegment: initURL, parts: main.map(\.url),
                                              audioInit: job.audioContainer == .fmp4 ? audioInit : nil,
                                              audioParts: job.audioContainer == .fmp4 ? audio.map(\.url) : [],
                                              output: out, progress: progress)
                return AssembledOutput(url: out, fileExtension: r.hasVideo ? "mp4" : "m4a",
                                       note: job.audioContainer != nil && job.audioContainer != .fmp4 ? "따로 있는 오디오는 합치지 못했어요" : nil)
            } catch {
                // 그냥 이어 붙여도 조각 MP4로 재생은 된다
                try? fm.removeItem(at: out)
                var files: [URL] = []
                if let initURL { files.append(initURL) }
                files += main.map(\.url)
                try concatenate(files, to: out, progress: progress)
                return AssembledOutput(url: out, fileExtension: "mp4",
                                       note: "조각 MP4 그대로 저장했어요(\(error.localizedDescription))")
            }
        }
    }

    func concatenate(_ files: [URL], to out: URL, progress: @Sendable (Double) -> Void) throws {
        let writer = try BufferedFileWriter(url: out)
        for (n, f) in files.enumerated() {
            try writer.write(Data(contentsOf: f, options: .alwaysMapped))
            progress(Double(n + 1) / Double(max(1, files.count)))
        }
        try writer.close()
    }
}
