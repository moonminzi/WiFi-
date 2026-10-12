import NagoTLCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var translator: Translator
    @EnvironmentObject private var router: Router
    @State private var picked: [PhotosPickerItem] = []
    @State private var busy = false
    @State private var renaming: BookRecord?
    @State private var newTitle = ""
    @State private var deleting: BookRecord?

    var body: some View {
        TermPage(path: "library") {
            if !AISettings.ready { keyBanner }
            addBlock
            let books = library.books.filter { $0.kind == .book }
            if books.isEmpty {
                TermBlock(label: "empty") {
                    Text("아직 책이 없어요. 위에서 망가 페이지(사진 앱), CBZ/ZIP·PDF·그림 파일을 가져오면 한 권으로 묶여요.")
                        .font(Term.mono(13))
                        .foregroundStyle(Term.muted)
                }
            } else {
                TermBlock(label: "books (\(books.count))") {
                    ForEach(Array(books.enumerated()), id: \.element.id) { i, b in
                        if i > 0 { TermDivider() }
                        NavigationLink(value: b.id) { BookRow(book: b) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button { newTitle = b.title; renaming = b } label: { Label("이름 바꾸기", systemImage: "pencil") }
                                Button(role: .destructive) { deleting = b } label: { Label("삭제", systemImage: "trash") }
                            }
                    }
                }
            }
        }
        .navigationTitle("")
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            Task { await importPhotos(items) }
        }
        .alert("이름 바꾸기", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("제목", text: $newTitle)
            Button("저장") {
                if let b = renaming, !newTitle.trimmingCharacters(in: .whitespaces).isEmpty {
                    library.updateBook(b.id) { $0.title = newTitle }
                }
                renaming = nil
            }
            Button("취소", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("이 책을 지울까요? 원본·번역 그림이 모두 지워져요.",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("삭제", role: .destructive) {
                if let b = deleting { library.deleteBook(b.id) }
                deleting = nil
            }
        }
    }

    private var keyBanner: some View {
        TermBlock(label: "setup") {
            StatusLine(kind: .warn, text: "번역 AI 키가 없어요")
            Text("번역은 Claude·Gemini·OpenAI 호환 AI 중 고른 것이 해요. 설정 탭에서 API 키를 한 번만 넣으면 돼요.")
                .font(Term.mono(12))
                .foregroundStyle(Term.muted)
            Button { router.tab = .settings } label: { Label("설정으로", systemImage: "key") }
                .buttonStyle(.term)
        }
    }

    private var addBlock: some View {
        TermBlock(label: "add") {
            HStack(spacing: 8) {
                PhotosPicker(selection: $picked, maxSelectionCount: 500, matching: .images, photoLibrary: .shared()) {
                    Label("사진 앱", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(TermButtonStyle(kind: .primary, fill: true))
                .disabled(busy)
                Button { pickFiles() } label: { Label("파일", systemImage: "folder") }
                    .buttonStyle(TermButtonStyle(kind: .secondary, fill: true))
                    .disabled(busy)
            }
            if busy || library.importing != nil {
                StatusLine(kind: .running, text: library.importing ?? "가져오는 중…")
            } else {
                Text("망가·웹툰 페이지, CBZ/ZIP(여러 권 묶음도), PDF. 그림 여러 장은 파일 이름 순서로 한 권, ZIP·PDF는 하나씩 한 권이 돼요.")
                    .font(Term.mono(11.5))
                    .foregroundStyle(Term.muted)
            }
        }
    }

    /// 파일 앱에서 고르기(ZIP·PDF·그림 여러 개). 고른 파일은 선택기가 앱 안으로 복사해 준다
    @MainActor
    private func pickFiles() {
        DocumentPicker.shared.present(types: Importer.fileTypes) { urls in
            Task { @MainActor in
                busy = true
                let ids = await Importer.importFiles(urls)
                busy = false
                if ids.count == 1 { router.path = [ids[0]] }
            }
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        busy = true
        defer {
            busy = false
            library.importing = nil
        }
        var datas: [Data] = []
        for (i, item) in items.enumerated() {
            library.importing = "사진 불러오는 중: \(i + 1)/\(items.count)장"
            if let d = try? await item.loadTransferable(type: Data.self) { datas.append(d) }
        }
        guard !datas.isEmpty else {
            library.show("사진을 불러오지 못했어요(iCloud 사진이면 사진 앱에서 한 번 열어 받은 뒤 다시)")
            return
        }
        library.importing = "가져오는 중: 사진 \(datas.count)장"
        let id = library.createBook(title: "사진 \(datas.count)장 · " + Date().formatted(date: .abbreviated, time: .shortened))
        _ = await Importer.importImages(datas, book: id)
        router.path = [id]
    }
}

struct BookRow: View {
    let book: BookRecord
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var translator: Translator

    var body: some View {
        let pages = library.pageList(book.id)
        let done = pages.filter { $0.status == .done }.count
        let left = translator.remaining(book: book.id)
        HStack(spacing: 12) {
            if let first = pages.first {
                ThumbView(url: Paths.thumb(book.id, first.id), version: first.version)
                    .frame(width: 48, height: 68)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Term.border))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title)
                    .font(Term.mono(14, .semibold))
                    .foregroundStyle(Term.text)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text("\(pages.count)쪽").foregroundStyle(Term.muted)
                    Text("번역 \(done)/\(pages.count)").foregroundStyle(done == pages.count && !pages.isEmpty ? Term.green : Term.muted)
                    if book.usage.dollars > 0 { Text(book.usage.costText).foregroundStyle(Term.amber) }
                }
                .font(Term.mono(11.5))
                if left > 0 {
                    StatusLine(kind: .running, text: "번역 중 · \(left)쪽 남음")
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").foregroundStyle(Term.muted).font(.system(size: 12))
        }
        .contentShape(Rectangle())
    }
}
