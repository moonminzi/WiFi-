import NagoTLCore
import PhotosUI
import SwiftUI

struct BookView: View {
    let bookID: String
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var translator: Translator
    @EnvironmentObject private var router: Router
    @State private var settings = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var exporting = false
    @State private var shareURL: URL?
    @State private var deletingPage: PageRecord?
    @State private var confirmRedo = false

    var body: some View {
        if let book = library.book(bookID) {
            content(book)
        } else {
            Text("책이 없어요").font(Term.mono(14)).foregroundStyle(Term.muted)
        }
    }

    private func content(_ book: BookRecord) -> some View {
        let pages = library.pageList(bookID)
        let done = pages.filter { $0.status == .done }.count
        let failed = pages.filter { $0.status == .failed }.count
        let left = translator.remaining(book: bookID)
        return TermPage(path: "book") {
            TermBlock(label: "info") {
                Text(book.title).font(Term.mono(16, .bold)).foregroundStyle(Term.text)
                HStack(spacing: 10) {
                    Text("\(pages.count)쪽")
                    Text("번역 \(done)").foregroundStyle(done > 0 ? Term.green : Term.muted)
                    if failed > 0 { Text("실패 \(failed)").foregroundStyle(Term.red) }
                    Text(book.usage.costText).foregroundStyle(Term.amber)
                    Text(library.direction(bookID).label)
                }
                .font(Term.mono(12))
                .foregroundStyle(Term.muted)
                if left > 0 { StatusLine(kind: .running, text: "번역 중 · \(left)쪽 남음 (앱을 켜 두세요)") }
                if done < pages.count && left == 0 {
                    let rest = pages.count - done
                    Text("남은 \(rest)쪽 예상 약 " + Usage.money(Double(rest) * AISettings.estimatedPageCost())
                        + " · 예산 남은 돈 " + Usage.money(Budget.remaining))
                        .font(Term.mono(11))
                        .foregroundStyle(Term.muted)
                }
                HStack(spacing: 8) {
                    if left > 0 {
                        Button { translator.cancel(book: bookID) } label: { Label("멈춤", systemImage: "pause") }
                            .buttonStyle(TermButtonStyle(kind: .secondary, fill: true))
                    } else {
                        Button {
                            if done == pages.count { confirmRedo = true } else { translateAll(pages) }
                        } label: {
                            Label(done == pages.count && !pages.isEmpty ? "모두 다시" : "전체 번역", systemImage: "character.bubble")
                        }
                        .buttonStyle(TermButtonStyle(kind: .primary, fill: true))
                        .disabled(pages.isEmpty)
                    }
                    Button { router.reader = ReaderTarget(book: bookID, start: 0) } label: {
                        Label("읽기", systemImage: "book")
                    }
                    .buttonStyle(TermButtonStyle(kind: .secondary, fill: true))
                    .disabled(pages.isEmpty)
                }
                HStack(spacing: 8) {
                    Menu {
                        Button { Task { await saveAllToPhotos(pages) } } label: { Label("사진 앱에 모두 저장", systemImage: "square.and.arrow.down") }
                        Button { Task { await exportCBZ(book, pages) } } label: { Label("CBZ로 내보내기", systemImage: "doc.zipper") }
                        Divider()
                        Button { Task { await translator.repaintAll(book: bookID) } } label: {
                            Label("모두 다시 그리기 · 무료(번역 그대로)", systemImage: "paintbrush")
                        }
                        .disabled(done == 0 || left > 0)
                    } label: {
                        Label("더보기", systemImage: "ellipsis.circle")
                    }
                    .buttonStyle(.term)
                    PhotosPicker(selection: $picked, maxSelectionCount: 500, matching: .images, photoLibrary: .shared()) {
                        Label("쪽 추가", systemImage: "plus")
                    }
                    .buttonStyle(.term)
                    Button { settings = true } label: { Label("작품 설정", systemImage: "slider.horizontal.3") }
                        .buttonStyle(.term)
                }
                if exporting { StatusLine(kind: .running, text: "만드는 중…") }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 10) {
                ForEach(Array(pages.enumerated()), id: \.element.id) { i, p in
                    PageCell(bookID: bookID, page: p, number: i + 1)
                        .onTapGesture { router.reader = ReaderTarget(book: bookID, start: i) }
                        .contextMenu {
                            Button { translator.enqueue(book: bookID, pages: [p.id], front: true) } label: {
                                Label(p.answer == nil ? "번역" : "다시 번역", systemImage: "arrow.clockwise")
                            }
                            Button(role: .destructive) { deletingPage = p } label: { Label("이 쪽 삭제", systemImage: "trash") }
                        }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $settings) {
            BookSettingsView(bookID: bookID).environmentObject(library).environmentObject(translator)
        }
        .sheet(item: Binding(get: { shareURL.map(ShareItem.init) }, set: { shareURL = $0?.url })) { item in
            ActivityView(items: [item.url])
        }
        .confirmationDialog("모든 쪽을 처음부터 다시 번역할까요? 직접 고친 번역은 원문이 같은 말풍선에 그대로 남아요.",
                            isPresented: $confirmRedo, titleVisibility: .visible) {
            Button("모두 다시 번역") { translator.enqueue(book: bookID, pages: library.pageList(bookID).map(\.id)) }
        }
        .confirmationDialog("이 쪽을 지울까요?", isPresented: Binding(get: { deletingPage != nil }, set: { if !$0 { deletingPage = nil } }),
                            titleVisibility: .visible) {
            Button("삭제", role: .destructive) {
                if let p = deletingPage { library.deletePages(book: bookID, ids: [p.id]) }
                deletingPage = nil
            }
        }
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            Task {
                var datas: [Data] = []
                for item in items {
                    if let d = try? await item.loadTransferable(type: Data.self) { datas.append(d) }
                }
                _ = await Importer.importImages(datas, book: bookID)
            }
        }
    }

    private func translateAll(_ pages: [PageRecord]) {
        let todo = pages.filter { $0.status != .done }
        translator.enqueue(book: bookID, pages: (todo.isEmpty ? pages : todo).map(\.id))
    }

    private func saveAllToPhotos(_ pages: [PageRecord]) async {
        let urls = pages.map { p in
            p.status == .done ? Paths.output(bookID, p.id) : Paths.original(bookID, p.file)
        }
        do {
            try await MediaSaver.save(urls)
            library.show("사진 앱에 \(urls.count)장 저장했어요")
        } catch {
            library.show(error.localizedDescription)
        }
    }

    private func exportCBZ(_ book: BookRecord, _ pages: [PageRecord]) async {
        exporting = true
        defer { exporting = false }
        let id = bookID
        let items = pages.map { p in
            p.status == .done ? Paths.output(id, p.id) : Paths.original(id, p.file)
        }
        let name = book.title.replacingOccurrences(of: "/", with: "-") + " (한국어).cbz"
        let url = await Task.detached(priority: .userInitiated) { () -> URL? in
            let dst = Paths.exports.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: dst)
            guard let w = try? ZipWriter(url: dst) else { return nil }
            for (i, src) in items.enumerated() {
                guard let data = try? Data(contentsOf: src) else { continue }
                try? w.add(name: String(format: "%04d.", i + 1) + src.pathExtension.lowercased(), data: data)
            }
            return (try? w.finish()) != nil ? dst : nil
        }.value
        if let url { shareURL = url } else { library.show("CBZ를 만들지 못했어요") }
    }
}

struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.path }
}

struct PageCell: View {
    let bookID: String
    let page: PageRecord
    let number: Int
    @EnvironmentObject private var translator: Translator

    var body: some View {
        VStack(spacing: 4) {
            ThumbView(url: Paths.thumb(bookID, page.id), version: page.version)
                .aspectRatio(0.7, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(page.status == .done ? Term.green.opacity(0.6) : Term.border))
                .overlay(alignment: .topTrailing) { badge.padding(4) }
            Text(label)
                .font(Term.mono(10.5))
                .foregroundStyle(page.status == .failed ? Term.red : Term.muted)
                .lineLimit(1)
        }
    }

    private var label: String {
        if let live = translator.live[page.id] { return "\(number) · \(live)" }
        switch page.status {
        case .pending: return "\(number)"
        case .queued: return "\(number) · 대기"
        case .working: return "\(number) · 번역 중"
        case .done: return "\(number)"
        case .failed: return "\(number) · 실패"
        }
    }

    @ViewBuilder private var badge: some View {
        switch page.status {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Term.green).font(.system(size: 15))
        case .working:
            ProgressView().controlSize(.small).tint(Term.green)
        case .queued:
            Image(systemName: "clock").foregroundStyle(Term.muted).font(.system(size: 13))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Term.red).font(.system(size: 14))
        case .pending:
            EmptyView()
        }
    }
}

/// 작품 설정: 제목, 읽는 방향, 메모(등장인물·말투), 용어집
struct BookSettingsView: View {
    let bookID: String
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var translator: Translator
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var note = ""
    @State private var direction: BookRecord.Direction = .auto
    @State private var glossary: [EditableTerm] = []
    @State private var loaded = false

    struct EditableTerm: Identifiable {
        let id = UUID()
        var source: String
        var korean: String
        var note: String
    }

    var body: some View {
        NavigationStack {
            TermPage(path: "book/settings") {
                TermBlock(label: "title") {
                    TermField(key: "제목", text: $title, placeholder: "작품 이름")
                }
                TermBlock(label: "direction") {
                    TermChoice(options: BookRecord.Direction.allCases.map { (label: $0.label, value: $0) }, selection: $direction)
                    Text("자동: 일본 망가는 오른쪽→왼쪽, 세로로 긴 웹툰은 세로 스크롤")
                        .font(Term.mono(11)).foregroundStyle(Term.muted)
                }
                TermBlock(label: "note") {
                    TextEditor(text: $note)
                        .font(Term.mono(13))
                        .frame(minHeight: 90)
                        .scrollContentBackground(.hidden)
                        .background(Term.bg)
                    Text("번역 때마다 Claude에게 같이 줘요. 예: \"주인공 유키는 여고생, 말투는 반말. 선배에게만 존댓말\"")
                        .font(Term.mono(11)).foregroundStyle(Term.muted)
                }
                TermBlock(label: "glossary (\(glossary.count))") {
                    Text("이름·지명·기술 이름을 늘 같은 말로 옮기게 해요. 번역하면서 자동으로 늘어나고, 여기서 고치면 다음 번역부터 그대로 써요.")
                        .font(Term.mono(11)).foregroundStyle(Term.muted)
                    ForEach($glossary) { $term in
                        HStack(spacing: 6) {
                            TextField("원어", text: $term.source)
                                .frame(maxWidth: 110)
                            Text("→").foregroundStyle(Term.muted)
                            TextField("한국어", text: $term.korean)
                            Button {
                                let id = term.id
                                glossary.removeAll { $0.id == id }
                            } label: { Image(systemName: "minus.circle") }
                                .foregroundStyle(Term.red)
                                .buttonStyle(.plain)
                        }
                        .font(Term.mono(13))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    }
                    Button { glossary.append(EditableTerm(source: "", korean: "", note: "")) } label: { Label("추가", systemImage: "plus") }
                        .buttonStyle(.term)
                }
                Button { save() } label: { Label("저장", systemImage: "checkmark") }
                    .buttonStyle(.termPrimary)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() }.font(Term.mono(14)) }
            }
        }
        .onAppear {
            guard !loaded, let b = library.book(bookID) else { return }
            loaded = true
            title = b.title
            note = b.note
            direction = b.direction
            glossary = b.glossary.map { EditableTerm(source: $0.source, korean: $0.korean, note: $0.note) }
        }
    }

    private func save() {
        let cleaned = glossary.filter {
            !$0.source.trimmingCharacters(in: .whitespaces).isEmpty && !$0.korean.trimmingCharacters(in: .whitespaces).isEmpty
        }.map { GlossaryEntry(source: $0.source, korean: $0.korean, note: $0.note) }
        library.updateBook(bookID) { b in
            if !title.trimmingCharacters(in: .whitespaces).isEmpty { b.title = title }
            b.note = note
            b.direction = direction
            b.glossary = cleaned
        }
        dismiss()
    }
}

/// 공유 시트
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
