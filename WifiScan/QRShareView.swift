import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct QRShareView: View {
    enum Mode: String, CaseIterable {
        case file, wifi, text
    }

    @AppStorage("qrMode") private var mode: Mode = .file
    @State private var qr: QRPayload?

    var body: some View {
        TermPage(path: "share") {
            TermChoice(options: Mode.allCases.map { (label: $0.rawValue, value: $0) }, selection: $mode)

            switch mode {
            case .file: FileShareSection(qr: $qr)
            case .wifi: WiFiShareSection(qr: $qr)
            case .text: TextShareSection(qr: $qr)
            }
        }
        .sheet(item: $qr) { QRSheet(payload: $0) }
    }
}

// MARK: - 파일

private struct FileShareSection: View {
    @Binding var qr: QRPayload?

    private let store = ShareStore.shared
    @AppStorage("shareHours") private var hours = 24
    @State private var pickerItem: PhotosPickerItem?
    @State private var showImporter = false
    @State private var progress: Double?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                PhotosPicker(selection: $pickerItem, matching: .any(of: [.images, .videos])) {
                    Label("photos", systemImage: "photo.on.rectangle")
                }
                Button { showImporter = true } label: {
                    Label("files", systemImage: "folder")
                }
            }
            .buttonStyle(TermButtonStyle(fill: true))
            .disabled(progress != nil)

            HStack(spacing: 10) {
                Text("ttl").font(Term.mono(13)).foregroundStyle(Term.muted)
                TermChoice(options: [("1h", 1), ("6h", 6), ("1d", 24), ("2d", 48)], selection: $hours)
                Spacer()
            }

            if let progress {
                UploadProgress(value: progress)
            } else if let errorMessage {
                StatusLine(kind: .error, text: errorMessage)
            } else {
                Text("tmpfiles.org · public link · ≤100MB")
                    .font(Term.mono(12))
                    .foregroundStyle(Term.muted)
            }

            let files = store.history.filter { !$0.isExpired }
            if !files.isEmpty {
                TermBlock(label: "active") {
                    ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                        if index > 0 { TermDivider() }
                        HStack(spacing: 10) {
                            Button {
                                qr = payload(for: file)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(file.name)
                                        .font(Term.mono(14))
                                        .foregroundStyle(Term.text)
                                        .lineLimit(1)
                                    Text("\(Self.sizeText(file.size)) · exp \(Self.expiryText(file.expiresAt))")
                                        .font(Term.mono(11))
                                        .foregroundStyle(Term.muted)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button { store.remove(file) } label: {
                                Image(systemName: "xmark")
                                    .font(Term.mono(12))
                                    .foregroundStyle(Term.muted)
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
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
        .link(file.url, title: file.name, subtitle: "\(Self.sizeText(file.size)) · exp \(Self.expiryText(file.expiresAt))")
    }

    private static func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func expiryText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "MM/dd HH:mm"
        return formatter.string(from: date)
    }
}

/// `[██████░░░░░░] 52%` 형태의 진행률
private struct UploadProgress: View {
    let value: Double
    private let width = 20

    var body: some View {
        let filled = Int((value * Double(width)).rounded())
        HStack(spacing: 8) {
            Text("[" + String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled) + "]")
                .foregroundStyle(Term.green)
            Text("\(Int(value * 100))%")
                .foregroundStyle(Term.muted)
        }
        .font(Term.mono(13))
        .lineLimit(1)
        .minimumScaleFactor(0.6)
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

private struct WiFiShareSection: View {
    @Binding var qr: QRPayload?

    private let store = WiFiStore.shared
    @State private var ssid = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            TermBlock(label: "new") {
                TermField(key: "ssid", text: $ssid, placeholder: "—")
                TermDivider()
                TermField(key: "pw", text: $password, placeholder: "open")
            }

            Button {
                store.save(ssid: ssid, password: password)
                qr = .wifi(ssid: ssid, password: password)
                ssid = ""
                password = ""
            } label: {
                Label("qr", systemImage: "qrcode")
            }
            .buttonStyle(.termPrimary)
            .disabled(ssid.trimmingCharacters(in: .whitespaces).isEmpty)

            if !store.networks.isEmpty {
                TermBlock(label: "saved") {
                    ForEach(Array(store.networks.enumerated()), id: \.element.id) { index, network in
                        if index > 0 { TermDivider() }
                        HStack(spacing: 10) {
                            Button {
                                qr = .wifi(ssid: network.ssid, password: network.password)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(network.ssid)
                                        .font(Term.mono(14))
                                        .foregroundStyle(Term.text)
                                    Text(network.password.isEmpty ? "open" : network.password)
                                        .font(Term.mono(11))
                                        .foregroundStyle(Term.muted)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button { store.delete(network) } label: {
                                Image(systemName: "xmark")
                                    .font(Term.mono(12))
                                    .foregroundStyle(Term.muted)
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 텍스트

private struct TextShareSection: View {
    @Binding var qr: QRPayload?
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            TermBlock(label: "input") {
                TextField("", text: $text, prompt: Text("text or url").foregroundStyle(Term.muted.opacity(0.5)), axis: .vertical)
                    .font(Term.mono(15))
                    .lineLimit(3...10)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    Spacer()
                    Text("\(text.utf8.count)/2900 B")
                        .font(Term.mono(11))
                        .foregroundStyle(text.utf8.count > 2900 ? Term.red : Term.muted)
                }
            }

            HStack(spacing: 8) {
                Button {
                    text = UIPasteboard.general.string ?? text
                } label: {
                    Label("paste", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.term)

                Button {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme) {
                        qr = .link(url, title: url.host() ?? trimmed, subtitle: nil)
                    } else {
                        qr = .text(trimmed)
                    }
                } label: {
                    Label("qr", systemImage: "qrcode")
                }
                .buttonStyle(.termPrimary)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
