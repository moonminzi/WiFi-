import SwiftUI
import UIKit
import QuickLook
import NagoDLCore

/// IDM처럼 연결마다 받은 구간을 칸으로 보여 주는 진행 막대
struct SegmentBar: View {
    var bars: [BarPiece]
    var progress: Double?
    var status: DownloadStatus
    var height: CGFloat = 9

    var body: some View {
        Canvas { ctx, size in
            let full = CGRect(origin: .zero, size: size)
            ctx.fill(Path(full), with: .color(Term.track))
            if status == .completed {
                ctx.fill(Path(full), with: .color(Term.green.opacity(0.85)))
                return
            }
            let fillColor: Color = status == .failed ? Term.red : (status == .paused ? Term.muted : Term.green)
            if bars.isEmpty {
                if let progress {
                    ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width * progress, height: size.height)), with: .color(fillColor))
                }
                return
            }
            for p in bars {
                let x0 = size.width * p.from
                let xf = size.width * p.filled
                if xf > x0 {
                    let color = p.external ? Term.amber : fillColor
                    ctx.fill(Path(CGRect(x: x0, y: 0, width: xf - x0, height: size.height)), with: .color(color))
                }
                if p.active && status == .running {
                    // 지금 받는 자리(연결 머리)
                    ctx.fill(Path(CGRect(x: max(0, xf - 1.5), y: 0, width: 3, height: size.height)), with: .color(Term.key))
                }
                if p.from > 0 {
                    // 구간 경계
                    ctx.fill(Path(CGRect(x: x0, y: 0, width: 1, height: size.height)), with: .color(Term.bg.opacity(0.9)))
                }
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

struct DownloadsView: View {
    @EnvironmentObject private var store: DownloadStore
    @EnvironmentObject private var router: Router
    @State private var detail: DownloadSnapshot?
    @State private var preview: URL?

    var body: some View {
        TermPage(path: "dl") {
            header
            if router.clipboardHasLink { clipboardBanner }
            if store.items.isEmpty {
                empty
            } else {
                ForEach(store.items.reversed()) { item in
                    DownloadRow(item: item, preview: $preview)
                        .contentShape(Rectangle())
                        .onTapGesture { detail = item }
                }
            }
        }
        .sheet(item: $detail) { item in
            DownloadDetailView(id: item.id, preview: $preview)
                .environmentObject(store)
                .environmentObject(router)
        }
        .quickLookPreview($preview)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                router.openAdd(AddRequest(text: "", autoProbe: false))
            } label: {
                Label("add", systemImage: "plus")
            }
            .buttonStyle(TermButtonStyle(kind: .primary))

            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(store.activeCount) active")
                    .foregroundStyle(store.activeCount > 0 ? Term.green : Term.muted)
                Text(ByteFormat.speed(store.totalSpeed))
                    .foregroundStyle(Term.num)
            }
            .font(Term.mono(12))
        }
    }

    private var clipboardBanner: some View {
        TermBlock(label: "clipboard") {
            HStack(spacing: 10) {
                Text("복사한 링크가 있어요")
                    .font(Term.mono(13))
                    .foregroundStyle(Term.text)
                Spacer(minLength: 0)
                PasteButton(payloadType: String.self) { strings in
                    let text = strings.joined(separator: "\n")
                    Task { @MainActor in
                        router.clipboardHandled()
                        if let url = LinkProbe.firstURL(in: text) {
                            router.openAdd(AddRequest(text: url.absoluteString))
                        } else {
                            store.show("링크를 찾지 못했어요")
                        }
                    }
                }
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.roundedRectangle)
                .tint(Term.green)
                Button {
                    router.clipboardHandled()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.term)
            }
        }
    }

    private var empty: some View {
        TermWindow(title: "nago-dl — help") {
            VStack(alignment: .leading, spacing: 10) {
                Text("$ dl --help").foregroundStyle(Term.green)
                Group {
                    Text("· add: 링크를 붙여 넣어 받기")
                    Text("· browser: 사이트에서 파일·동영상(m3u8 포함) 잡기")
                    Text("· 다른 앱의 공유 → NAGO DL")
                    Text("· 연결을 여러 개로 나눠 받아서 빠르고, 끊겨도 이어 받아요")
                    Text("· 받은 파일: 파일 앱 → 나의 iPhone → NAGO DL")
                }
                .foregroundStyle(Term.muted)
            }
            .font(Term.mono(13))
        }
    }
}

struct DownloadRow: View {
    @EnvironmentObject private var store: DownloadStore
    let item: DownloadSnapshot
    @Binding var preview: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(icon)
                    .foregroundStyle(statusColor)
                Text(item.fileName)
                    .font(Term.mono(14, .semibold))
                    .foregroundStyle(item.fileMissing ? Term.muted : Term.text)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                actionButton
            }
            .font(Term.mono(14))

            if item.status != .completed {
                SegmentBar(bars: item.bars, progress: item.progress, status: item.status)
            }

            Text(line)
                .font(Term.mono(11.5))
                .foregroundStyle(item.status == .failed ? Term.red : Term.muted)
                .lineLimit(3)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Term.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Term.border, lineWidth: 1))
        .contextMenu { DownloadMenu(item: item, preview: $preview) }
    }

    private var icon: String {
        switch item.status {
        case .queued: "…"
        case .running: "↓"
        case .paused: "‖"
        case .processing: "⚙"
        case .completed: item.fileMissing ? "?" : "✓"
        case .failed: "✗"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .running, .processing: Term.green
        case .completed: item.fileMissing ? Term.muted : Term.green
        case .failed: Term.red
        case .paused, .queued: Term.amber
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch item.status {
        case .running, .queued:
            Button { store.pause(item.id) } label: { Image(systemName: "pause.fill") }
                .buttonStyle(.term)
        case .paused, .failed:
            Button { store.resume(item.id) } label: { Image(systemName: "play.fill") }
                .buttonStyle(.term)
        case .completed:
            if let url = item.savedURL, !item.fileMissing {
                Button { preview = url } label: { Image(systemName: "eye") }
                    .buttonStyle(.term)
            }
        case .processing:
            ProgressView().controlSize(.small).tint(Term.green)
        }
    }

    private var line: String {
        var parts: [String] = []
        switch item.status {
        case .completed:
            if item.fileMissing { return "파일이 없어요(파일 앱에서 지웠거나 옮김)" }
            if let total = item.totalBytes { parts.append(ByteFormat.size(total)) }
            if let date = item.completedAt { parts.append(Self.dateFormatter.string(from: date)) }
            if let detail = item.detail { parts.append(detail) }
            return "✓ " + parts.joined(separator: " · ")
        case .failed:
            return item.errorMessage ?? "실패"
        default:
            break
        }
        if let total = item.totalBytes, total > 0 {
            parts.append("\(ByteFormat.size(item.doneBytes)) / \(ByteFormat.size(total))")
            if let p = item.progress { parts.append("\(Int((p * 100).rounded(.down)))%") }
        } else {
            parts.append(ByteFormat.size(item.doneBytes))
        }
        if item.status == .running {
            parts.append(ByteFormat.speed(item.speed))
            if let eta = item.eta { parts.append(ByteFormat.duration(eta)) }
            if item.activeConnections > 0 { parts.append("\(item.activeConnections) conn") }
            if item.backgroundParts > 0 { parts.append("bg \(item.backgroundParts)") }
        } else if item.status == .queued {
            parts.append("대기")
        } else if item.status == .paused {
            parts.append("일시정지")
        }
        var text = parts.joined(separator: " · ")
        if let detail = item.detail { text += "\n" + detail }
        return text
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        return f
    }()
}

/// 길게 눌렀을 때 메뉴(목록·상세 공통)
struct DownloadMenu: View {
    @EnvironmentObject private var store: DownloadStore
    let item: DownloadSnapshot
    @Binding var preview: URL?

    var body: some View {
        switch item.status {
        case .running, .queued:
            Button { store.pause(item.id) } label: { Label("일시정지", systemImage: "pause") }
        case .paused, .failed:
            Button { store.resume(item.id) } label: { Label("이어 받기", systemImage: "play") }
        default:
            EmptyView()
        }
        if let url = item.savedURL, item.status == .completed, !item.fileMissing {
            Button { preview = url } label: { Label("열기", systemImage: "eye") }
            ShareLink(item: url) { Label("공유", systemImage: "square.and.arrow.up") }
            if MediaSaver.canSave(url) {
                Button {
                    Task {
                        do {
                            try await MediaSaver.save(url)
                            store.show("사진 앱에 저장했어요")
                        } catch {
                            store.show(error.localizedDescription)
                        }
                    }
                } label: { Label("사진 앱에 저장", systemImage: "photo.on.rectangle") }
            }
        }
        Button {
            UIPasteboard.general.string = item.sourceURL.absoluteString
            store.show("링크를 복사했어요")
        } label: { Label("링크 복사", systemImage: "link") }
        Divider()
        Button(role: .destructive) { store.remove(item.id, deleteFile: false) } label: {
            Label(item.status == .completed ? "목록에서 지우기" : "취소하고 지우기", systemImage: "xmark")
        }
        if item.status == .completed && !item.fileMissing {
            Button(role: .destructive) { store.remove(item.id, deleteFile: true) } label: {
                Label("파일까지 지우기", systemImage: "trash")
            }
        }
    }
}
