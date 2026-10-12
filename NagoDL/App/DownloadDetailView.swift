import SwiftUI
import UIKit
import NagoDLCore

/// 다운로드 한 건의 자세한 상태: 연결별 구간, 링크, 이름 바꾸기, 링크 갈아 끼우기
struct DownloadDetailView: View {
    @EnvironmentObject private var store: DownloadStore
    @EnvironmentObject private var router: Router
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @Binding var preview: URL?
    @State private var newName = ""
    @State private var newURL = ""
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Group {
                if let item = store.item(id) {
                    content(item)
                } else {
                    TermPage(path: "dl/info") {
                        Text("지워진 항목이에요").foregroundStyle(Term.muted)
                    }
                }
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
    }

    @ViewBuilder
    private func content(_ item: DownloadSnapshot) -> some View {
        TermPage(path: "dl/info") {
            TermBlock(label: "file") {
                Text(item.fileName)
                    .font(Term.mono(15, .semibold))
                    .textSelection(.enabled)
                SegmentBar(bars: item.bars, progress: item.progress, status: item.status, height: 12)
                infoLine("status", statusText(item), color: item.status == .failed ? Term.red : Term.text)
                if let total = item.totalBytes {
                    infoLine("size", "\(ByteFormat.size(item.doneBytes)) / \(ByteFormat.size(total))")
                } else {
                    infoLine("size", ByteFormat.size(item.doneBytes))
                }
                if item.status == .running {
                    infoLine("speed", ByteFormat.speed(item.speed) + (item.eta.map { " · " + ByteFormat.duration($0) + " 남음" } ?? ""))
                }
                if item.kind == .file {
                    infoLine("conn", "\(item.activeConnections)/\(item.maxConnections)" + (item.acceptsRanges ? "" : " · 이어받기 불가"))
                }
                if item.backgroundParts > 0 {
                    infoLine("bg", "\(item.backgroundParts)개 구간을 시스템이 받는 중")
                }
                if let mime = item.mimeType { infoLine("type", mime) }
                if let detail = item.detail { infoLine("note", detail) }
            }

            actions(item)

            if !item.connections.isEmpty {
                TermBlock(label: "connections") {
                    ForEach(item.connections) { c in
                        connectionLine(item, c)
                    }
                }
            }

            TermBlock(label: "link") {
                Text(item.sourceURL.absoluteString)
                    .font(Term.mono(12))
                    .foregroundStyle(Term.path)
                    .textSelection(.enabled)
                    .lineLimit(6)
                if let page = item.pageURL {
                    Text("page: " + page.absoluteString)
                        .font(Term.mono(11))
                        .foregroundStyle(Term.muted)
                        .lineLimit(3)
                }
                Button {
                    UIPasteboard.general.string = item.sourceURL.absoluteString
                    store.show("링크를 복사했어요")
                } label: { Label("링크 복사", systemImage: "link") }
                    .buttonStyle(.term)
            }

            if item.status != .completed && item.kind == .file {
                TermBlock(label: "refresh link") {
                    Text("링크가 만료됐으면 같은 파일의 새 링크를 넣어 받던 곳부터 이어 받아요")
                        .font(Term.mono(12))
                        .foregroundStyle(Term.muted)
                    TermField(key: "url", text: $newURL, placeholder: "https://…", keyboard: .URL)
                    Button {
                        if let url = LinkProbe.firstURL(in: newURL) {
                            store.updateURL(id, url: url)
                            newURL = ""
                            store.show("새 링크로 이어 받아요")
                        } else {
                            store.show("링크가 아니에요")
                        }
                    } label: { Label("이 링크로 이어 받기", systemImage: "arrow.triangle.2.circlepath") }
                        .buttonStyle(.term)
                        .disabled(newURL.isEmpty)
                }
            }

            TermBlock(label: "rename") {
                TermField(key: "name", text: $newName, placeholder: item.fileName)
                Button {
                    let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    store.rename(id, to: name)
                    newName = ""
                } label: { Label("이름 바꾸기", systemImage: "pencil") }
                    .buttonStyle(.term)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("지우기", systemImage: "trash").frame(maxWidth: .infinity)
            }
            .buttonStyle(TermButtonStyle(kind: .danger, fill: true))
            .confirmationDialog("지울까요?", isPresented: $confirmDelete, titleVisibility: .visible) {
                if item.status == .completed && !item.fileMissing {
                    Button("파일까지 지우기", role: .destructive) {
                        store.remove(id, deleteFile: true)
                        dismiss()
                    }
                }
                Button(item.status == .completed ? "목록에서만 지우기" : "취소하고 지우기", role: .destructive) {
                    store.remove(id, deleteFile: false)
                    dismiss()
                }
                Button("그만두기", role: .cancel) {}
            }
        }
    }

    @ViewBuilder
    private func actions(_ item: DownloadSnapshot) -> some View {
        HStack(spacing: 8) {
            switch item.status {
            case .running, .queued:
                Button { store.pause(id) } label: { Label("일시정지", systemImage: "pause.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(TermButtonStyle(kind: .secondary, fill: true))
            case .paused, .failed:
                Button { store.resume(id) } label: { Label("이어 받기", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(TermButtonStyle(kind: .primary, fill: true))
            case .completed:
                if let url = item.savedURL, !item.fileMissing {
                    Button { preview = url } label: { Label("열기", systemImage: "eye").frame(maxWidth: .infinity) }
                        .buttonStyle(TermButtonStyle(kind: .primary, fill: true))
                    ShareLink(item: url) { Label("공유", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity) }
                        .buttonStyle(TermButtonStyle(kind: .secondary, fill: true))
                }
            case .processing:
                StatusLine(kind: .running, text: item.detail ?? "합치는 중")
            }
        }
        if item.status == .completed, let url = item.savedURL, !item.fileMissing, MediaSaver.canSave(url) {
            Button {
                Task {
                    do {
                        try await MediaSaver.save(url)
                        store.show("사진 앱에 저장했어요")
                    } catch {
                        store.show(error.localizedDescription)
                    }
                }
            } label: { Label("사진 앱에 저장", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity) }
                .buttonStyle(TermButtonStyle(kind: .secondary, fill: true))
        }
    }

    private func connectionLine(_ item: DownloadSnapshot, _ c: ConnectionSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("#\(c.id)").foregroundStyle(Term.key).frame(width: 34, alignment: .leading)
            if item.kind == .hls {
                Text(c.note ?? "").foregroundStyle(Term.text)
                Spacer(minLength: 0)
                Text(ByteFormat.size(c.received)).foregroundStyle(Term.muted)
            } else if let note = c.note {
                Text(note).foregroundStyle(Term.muted).lineLimit(2)
                Spacer(minLength: 0)
            } else {
                let length = max(1, c.rangeEnd - c.rangeStart + 1)
                Text("\(ByteFormat.size(c.rangeStart))–\(ByteFormat.size(c.rangeEnd + 1))")
                    .foregroundStyle(Term.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Text("\(Int(Double(c.received) * 100 / Double(length)))%").foregroundStyle(Term.num)
            }
            Text(ByteFormat.speed(c.speed)).foregroundStyle(Term.green).frame(width: 92, alignment: .trailing)
        }
        .font(Term.mono(12))
    }

    private func infoLine(_ key: String, _ value: String, color: Color = Term.text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key).foregroundStyle(Term.muted).frame(width: 52, alignment: .leading)
            Text(value).foregroundStyle(color).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(Term.mono(13))
    }

    private func statusText(_ item: DownloadSnapshot) -> String {
        switch item.status {
        case .queued: "대기 중"
        case .running: "받는 중"
        case .paused: "일시정지"
        case .processing: "합치는 중"
        case .completed: item.fileMissing ? "완료(파일이 없어짐)" : "완료"
        case .failed: item.errorMessage ?? "실패"
        }
    }
}
