import SwiftUI
import UIKit
import NagoDLCore

/// 링크를 넣고 → 확인(크기·종류·화질) → 받기
struct AddDownloadView: View {
    enum Phase {
        case idle
        case probing
        case file(LinkInfo)
        case hls(HLSLoader.Info)
        case page(URL)
        case failed(String, URL?)
    }

    @EnvironmentObject private var store: DownloadStore
    @EnvironmentObject private var router: Router
    @Environment(\.dismiss) private var dismiss
    let request: AddRequest

    @State private var text: String
    @State private var phase: Phase = .idle
    @State private var name = ""
    @State private var connections: Int
    @State private var variantID: String?
    @State private var preparing = false
    @State private var task: Task<Void, Never>?

    init(request: AddRequest) {
        self.request = request
        _text = State(initialValue: request.text)
        let saved = UserDefaults.standard.integer(forKey: Pref.connections)
        _connections = State(initialValue: saved > 0 ? saved : 8)
    }

    var body: some View {
        NavigationStack {
            TermPage(path: "dl/add") {
                TermBlock(label: "link") {
                    TermField(key: "url", text: $text, placeholder: "https://…", keyboard: .URL)
                        .onSubmit { probe() }
                    HStack(spacing: 8) {
                        PasteButton(payloadType: String.self) { strings in
                            let pasted = strings.joined(separator: "\n")
                            Task { @MainActor in
                                text = LinkProbe.firstURL(in: pasted)?.absoluteString ?? pasted
                                router.clipboardHandled()
                                probe()
                            }
                        }
                        .labelStyle(.iconOnly)
                        .buttonBorderShape(.roundedRectangle)
                        .tint(Term.green)
                        Button { probe() } label: { Label("확인", systemImage: "magnifyingglass") }
                            .buttonStyle(.term)
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Spacer(minLength: 0)
                    }
                }
                phaseView
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { dismiss() }
                        .font(Term.mono(14, .semibold))
                        .tint(Term.green)
                }
            }
            .toolbarBackground(Term.bg, for: .navigationBar)
        }
        .onAppear {
            if request.autoProbe && !text.isEmpty { probe() }
        }
        .onDisappear { task?.cancel() }
    }

    @ViewBuilder
    private var phaseView: some View {
        switch phase {
        case .idle:
            Text("파일 링크, m3u8 동영상 링크, 또는 웹 페이지 주소를 넣으세요")
                .font(Term.mono(12))
                .foregroundStyle(Term.muted)
        case .probing:
            StatusLine(kind: .running, text: "링크 확인 중")
        case .file(let info):
            fileView(info)
        case .hls(let info):
            hlsView(info)
        case .page(let url):
            TermBlock(label: "web page") {
                Text("웹 페이지예요. 브라우저로 열면 그 페이지의 동영상과 파일 링크를 찾아 드려요.")
                    .font(Term.mono(13))
                    .foregroundStyle(Term.text)
                Button {
                    router.openInBrowser(url)
                    dismiss()
                } label: { Label("브라우저에서 열기", systemImage: "safari").frame(maxWidth: .infinity) }
                    .buttonStyle(TermButtonStyle(kind: .primary, fill: true))
            }
        case .failed(let message, let url):
            TermBlock(label: "error") {
                StatusLine(kind: .error, text: message)
                if let url {
                    Button {
                        start(url: url, hls: nil)
                    } label: { Label("그래도 받아 보기", systemImage: "arrow.down").frame(maxWidth: .infinity) }
                        .buttonStyle(TermButtonStyle(kind: .secondary, fill: true))
                }
            }
        }
    }

    // MARK: 파일

    private func fileView(_ info: LinkInfo) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            TermBlock(label: "file") {
                TermField(key: "name", text: $name)
                line("size", info.totalBytes.map { ByteFormat.size($0) } ?? "크기 모름")
                line("type", info.mimeType ?? "모름")
                line("host", info.url.host ?? "")
                line("resume", info.acceptsRanges ? "이어받기 · 나눠 받기 됨" : "안 됨(연결 1개)",
                     color: info.acceptsRanges ? Term.green : Term.amber)
                if let total = info.totalBytes, let free = Self.freeSpace(), total > free {
                    StatusLine(kind: .warn, text: "저장 공간이 모자라요(남은 공간 \(ByteFormat.size(free)))")
                }
            }
            if info.acceptsRanges {
                connectionPicker
            }
            Button {
                start(url: URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? info.url, hls: nil)
            } label: { Label("받기", systemImage: "arrow.down.circle.fill").frame(maxWidth: .infinity) }
                .buttonStyle(TermButtonStyle(kind: .primary, fill: true))
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: HLS

    private func hlsView(_ info: HLSLoader.Info) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            TermBlock(label: "video (m3u8)") {
                TermField(key: "name", text: $name)
                if let media = info.media {
                    line("length", ByteFormat.duration(media.duration))
                    line("parts", "\(media.segments.count)개 조각")
                }
                Text("조각을 여러 개 동시에 받은 뒤 MP4로 합쳐요(다시 인코딩하지 않아서 화질 그대로)")
                    .font(Term.mono(11.5))
                    .foregroundStyle(Term.muted)
            }
            if !info.variants.isEmpty {
                TermBlock(label: "quality") {
                    ForEach(info.variants) { v in
                        Button {
                            variantID = v.id
                        } label: {
                            HStack(spacing: 10) {
                                Text(variantID == v.id ? "●" : "○")
                                    .foregroundStyle(variantID == v.id ? Term.green : Term.muted)
                                Text(v.label)
                                    .foregroundStyle(Term.text)
                                Spacer(minLength: 0)
                                if let codecs = v.codecs {
                                    Text(codecs.split(separator: ",").first.map(String.init) ?? "")
                                        .foregroundStyle(Term.muted)
                                        .lineLimit(1)
                                }
                            }
                            .font(Term.mono(13))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            connectionPicker
            Button {
                startHLS(info)
            } label: {
                HStack {
                    if preparing { ProgressView().tint(Term.bg) }
                    Label(preparing ? "목록 준비 중" : "받기", systemImage: "arrow.down.circle.fill")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(TermButtonStyle(kind: .primary, fill: true))
            .disabled(preparing || name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var connectionPicker: some View {
        TermBlock(label: "connections") {
            TermChoice(options: [1, 2, 4, 8, 16].map { (label: "\($0)", value: $0) }, selection: $connections)
            Text("연결을 여러 개 열어 나눠 받아요. 서버가 막으면 알아서 줄여요.")
                .font(Term.mono(11))
                .foregroundStyle(Term.muted)
        }
    }

    private func line(_ key: String, _ value: String, color: Color = Term.text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key).foregroundStyle(Term.muted).frame(width: 56, alignment: .leading)
            Text(value).foregroundStyle(color).lineLimit(2)
            Spacer(minLength: 0)
        }
        .font(Term.mono(13))
    }

    // MARK: 동작

    private func probe() {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = LinkProbe.firstURL(in: raw) ?? LinkProbe.urlFromAddressBar(raw) else {
            phase = .failed("링크가 아니에요(http/https 주소를 넣어 주세요)", nil)
            return
        }
        text = url.absoluteString
        phase = .probing
        let headers = request.headers
        let suggested = request.suggestedName
        task?.cancel()
        task = Task {
            do {
                let info = try await LinkProbe.inspect(url, headers: headers)
                guard !Task.isCancelled else { return }
                switch info.kind {
                case .hls:
                    let hls = try await HLSLoader.load(info.url, headers: headers)
                    guard !Task.isCancelled else { return }
                    name = FileNamer.replacingExtension(suggested ?? info.suggestedName, with: "mp4")
                    variantID = hls.variants.first?.id
                    phase = .hls(hls)
                case .page:
                    phase = .page(info.url)
                case .file:
                    if !(200..<300).contains(info.statusCode) && info.statusCode != 416 {
                        phase = .failed(ChannelError.http(info.statusCode).localizedDescription, url)
                        return
                    }
                    name = suggested ?? info.suggestedName
                    phase = .file(info)
                }
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription, url)
            }
        }
    }

    private func start(url: URL, hls: HLSJob?) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        store.add(NewDownload(url: url, fileName: clean.isEmpty ? nil : clean, headers: request.headers,
                              pageURL: request.pageURL, connections: connections, hls: hls))
        router.tab = .downloads
        dismiss()
    }

    private func startHLS(_ info: HLSLoader.Info) {
        preparing = true
        let headers = request.headers
        let variant = info.variants.first { $0.id == variantID }
        task = Task {
            do {
                let job = try await HLSLoader.makeJob(info, variant: variant, headers: headers)
                var fileName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if fileName.isEmpty { fileName = "video.mp4" }
                name = fileName
                start(url: info.url, hls: job)
            } catch {
                preparing = false
                phase = .failed(error.localizedDescription, nil)
            }
        }
    }

    nonisolated static func freeSpace() -> Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
