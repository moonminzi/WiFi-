import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct QRShareView: View {
    enum Mode: String, CaseIterable {
        case file = "파일"
        case wifi = "와이파이"
        case text = "텍스트"
    }

    @AppStorage("qrMode") private var mode: Mode = .file
    @State private var qr: QRPayload?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("종류", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                switch mode {
                case .file: FileShareSections(qr: $qr)
                case .wifi: WiFiShareSections(qr: $qr)
                case .text: TextShareSections(qr: $qr)
                }
            }
            .navigationTitle("QR 공유")
            .sheet(item: $qr) { QRSheet(payload: $0) }
        }
    }
}

// MARK: - 파일

private struct FileShareSections: View {
    @Binding var qr: QRPayload?

    private let store = ShareStore.shared
    @AppStorage("shareHours") private var hours = 24
    @State private var pickerItem: PhotosPickerItem?
    @State private var showImporter = false
    @State private var progress: Double?
    @State private var errorMessage: String?

    var body: some View {
        uploadSection
        historySection
    }

    private var uploadSection: some View {
        Section {
            HStack(spacing: 10) {
                PhotosPicker(selection: $pickerItem, matching: .any(of: [.images, .videos])) {
                    SourceLabel(title: "사진·동영상", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.bordered)
                SourceButton(title: "파일", systemImage: "folder") { showImporter = true }
            }
            .disabled(progress != nil)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            Picker("공유 기간", selection: $hours) {
                Text("1시간").tag(1)
                Text("6시간").tag(6)
                Text("1일").tag(24)
                Text("2일").tag(48)
            }

            if let progress {
                ProgressView(value: progress) {
                    Text("올리는 중… \(Int(progress * 100))%")
                }
            }
        } footer: {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            } else {
                Text("tmpfiles.org에 100MB까지 올라가고, 기간이 지나면 지워져요. 링크를 아는 사람은 누구나 받을 수 있으니 민감한 파일은 올리지 마세요.")
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            Task { await shareImported(url) }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            pickerItem = nil
            Task { await sharePicked(item) }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        let files = store.history.filter { !$0.isExpired }
        if !files.isEmpty {
            Section {
                ForEach(files) { file in
                    Button {
                        qr = payload(for: file)
                    } label: {
                        HStack {
                            Image(systemName: "qrcode")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name).lineLimit(1)
                                Text("\(Self.sizeText(file.size)) · \(file.expiresAt.formatted(date: .abbreviated, time: .shortened))까지")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    .swipeActions {
                        Button("목록에서 빼기", role: .destructive) { store.remove(file) }
                    }
                }
            } header: {
                Text("공유 중")
            } footer: {
                Text("누르면 QR을 다시 볼 수 있어요.")
            }
        }
    }

    // MARK: 업로드

    private func sharePicked(_ item: PhotosPickerItem) async {
        do {
            let dir = try Self.makeTempDirectory()
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { return }
                let dest = dir.appendingPathComponent(movie.name)
                try FileManager.default.moveItem(at: movie.url, to: dest)
                await share(fileAt: dest, name: dest.lastPathComponent)
            } else {
                guard let data = try await item.loadTransferable(type: Data.self) else { return }
                let type = item.supportedContentTypes.first
                var fileData = data
                var ext = type?.preferredFilenameExtension ?? "jpg"
                // 아이폰 기본 HEIC는 안드로이드·PC에서 잘 안 열려서 JPEG로 바꾼다
                if type?.conforms(to: .heic) == true || type?.conforms(to: .heif) == true,
                   let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.9) {
                    fileData = jpeg
                    ext = "jpg"
                }
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd_HHmmss"
                let dest = dir.appendingPathComponent("IMG_\(formatter.string(from: .now)).\(ext)")
                try fileData.write(to: dest)
                await share(fileAt: dest, name: dest.lastPathComponent)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func shareImported(_ url: URL) async {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let dest = try Self.makeTempDirectory().appendingPathComponent(url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: dest)
            await share(fileAt: dest, name: url.lastPathComponent)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func share(fileAt url: URL, name: String) async {
        errorMessage = nil
        progress = 0
        defer {
            progress = nil
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        do {
            let file = try await store.upload(fileAt: url, name: name, hours: hours) { value in
                Task { @MainActor in
                    if progress != nil { progress = value }
                }
            }
            qr = payload(for: file)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func payload(for file: SharedFile) -> QRPayload {
        .link(
            file.url,
            title: file.name,
            subtitle: "\(Self.sizeText(file.size)) · \(file.expiresAt.formatted(date: .abbreviated, time: .shortened))까지")
    }

    private static func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// 사진 앱의 동영상을 메모리에 다 올리지 않고 파일째로 받는다.
private struct PickedMovie: Transferable {
    let url: URL
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "-" + received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return PickedMovie(url: dest, name: received.file.lastPathComponent)
        }
    }
}

// MARK: - 와이파이

private struct WiFiShareSections: View {
    @Binding var qr: QRPayload?

    private let store = WiFiStore.shared
    @State private var ssid = ""
    @State private var password = ""

    var body: some View {
        Section {
            TextField("네트워크 이름", text: $ssid)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("비밀번호 (없으면 비워 두기)", text: $password)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                store.save(ssid: ssid, password: password)
                qr = .wifi(ssid: ssid, password: password)
                ssid = ""
                password = ""
            } label: {
                Label("QR 만들기", systemImage: "qrcode")
            }
            .disabled(ssid.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text("직접 입력")
        } footer: {
            Text("상대가 기본 카메라로 찍으면 비밀번호 입력 없이 바로 연결돼요.")
        }

        if !store.networks.isEmpty {
            Section("저장된 와이파이") {
                ForEach(store.networks) { network in
                    Button {
                        qr = .wifi(ssid: network.ssid, password: network.password)
                    } label: {
                        HStack {
                            Image(systemName: "wifi")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(network.ssid)
                                Text(network.password.isEmpty ? "비밀번호 없음" : network.password)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    .swipeActions {
                        Button("삭제", role: .destructive) { store.delete(network) }
                    }
                }
            }
        }
    }
}

// MARK: - 텍스트

private struct TextShareSections: View {
    @Binding var qr: QRPayload?
    @State private var text = ""

    var body: some View {
        Section {
            TextField("링크나 글자", text: $text, axis: .vertical)
                .lineLimit(3...8)
            Button {
                text = UIPasteboard.general.string ?? text
            } label: {
                Label("복사한 내용 붙여넣기", systemImage: "doc.on.clipboard")
            }
            Button {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme) {
                    qr = .link(url, title: url.host() ?? trimmed, subtitle: trimmed)
                } else {
                    qr = .text(trimmed)
                }
            } label: {
                Label("QR 만들기", systemImage: "qrcode")
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } footer: {
            Text("\(text.utf8.count) / 약 2,900바이트")
        }
    }
}
