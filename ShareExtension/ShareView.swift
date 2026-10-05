import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 공유받은 것(이미지·텍스트·링크·파일)을 읽어서 와이파이·계좌를 찾고, 파일은 올려서 QR로 보여준다.
@MainActor
@Observable
final class ShareModel {
    enum Phase { case loading, ready, empty }

    private weak var context: NSExtensionContext?
    var phase: Phase = .loading
    var image: UIImage?
    var isScanning = false
    var hasWiFi = false
    var ssid = ""
    var password = ""
    var accounts: [AccountCandidate] = []
    var text: String?
    var link: URL?
    var file: URL?
    var fileSize: Int64 = 0
    var progress: Double?
    var uploadError: String?

    init(context: NSExtensionContext?) {
        self.context = context
    }

    func close() {
        context?.completeRequest(returningItems: nil)
    }

    func load() async {
        let items = context?.inputItems as? [NSExtensionItem] ?? []
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                guard let url = await SharedItemLoader.loadFile(from: provider, conformingTo: .image) else { continue }
                setFile(url)
                if let image = UIImage(contentsOfFile: url.path()) {
                    self.image = image
                    phase = .ready
                    await recognize(image)
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                      !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                link = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let shared = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    text = shared
                    accounts = AccountParser.parse(shared)
                }
            } else if let url = await SharedItemLoader.loadFile(from: provider, conformingTo: .data) {
                setFile(url)
            }
        }
        let empty = image == nil && link == nil && text == nil && file == nil
        phase = empty ? .empty : .ready
    }

    func upload(hours: Int) async -> SharedFile? {
        guard let file else { return nil }
        uploadError = nil
        progress = 0
        defer { progress = nil }
        do {
            let dir = try SharedItemLoader.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            var dest = dir.appendingPathComponent(file.lastPathComponent)
            try FileManager.default.copyItem(at: file, to: dest)
            dest = ShareStore.convertingHEICToJPEG(dest)
            return try await ShareStore.shared.upload(fileAt: dest, name: dest.lastPathComponent, hours: hours) { value in
                Task { @MainActor in
                    if self.progress != nil { self.progress = value }
                }
            }
        } catch {
            uploadError = error.localizedDescription
            return nil
        }
    }

    // MARK: - 내부

    private func setFile(_ url: URL) {
        file = url
        fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    private func recognize(_ image: UIImage) async {
        isScanning = true
        defer { isScanning = false }

        let lines = (try? await TextRecognizer.recognize(image, languages: ["ko-KR", "en-US"])) ?? []
        var credentials = CredentialParser.parse(lines)
        if !credentials.isComplete, let english = try? await TextRecognizer.recognize(image, languages: ["en-US"]) {
            let second = CredentialParser.parse(english)
            if second.fieldCount > credentials.fieldCount { credentials = second }
        }
        if let foundSSID = credentials.ssid {
            hasWiFi = true
            ssid = foundSSID
            password = credentials.password ?? ""
        }

        // 숫자로만 된 와이파이 비번이 계좌번호로 잡히지 않게 뺀다
        let passwordDigits = password.filter(\.isNumber)
        accounts = AccountParser.parse(AccountParser.joinRows(lines))
            .filter { !(hasWiFi && $0.bank == nil && $0.digits == passwordDigits) }
    }
}

/// NSItemProvider 콜백은 백그라운드 큐에서 불리므로 메인 액터 밖에 둔다.
enum SharedItemLoader {
    static func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 파일로 받을 수 있으면 파일째로, 아니면(스크린샷 편집기처럼 메모리에만 있는 이미지) 직접 써서 임시 파일로 만든다.
    static func loadFile(from provider: NSItemProvider, conformingTo type: UTType) async -> URL? {
        let identifier = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: type) == true }
            ?? type.identifier

        let copied: URL? = await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, _ in
                // 이 콜백이 끝나면 원본 임시 파일이 지워지므로 여기서 복사한다
                guard let url, let dir = try? Self.makeTempDirectory() else {
                    continuation.resume(returning: nil)
                    return
                }
                let dest = dir.appendingPathComponent(url.lastPathComponent)
                continuation.resume(returning: (try? FileManager.default.copyItem(at: url, to: dest)) != nil ? dest : nil)
            }
        }
        if let copied { return copied }

        guard let item = try? await provider.loadItem(forTypeIdentifier: identifier),
              let dir = try? Self.makeTempDirectory()
        else { return nil }
        switch item {
        case let url as URL:
            let dest = dir.appendingPathComponent(url.lastPathComponent)
            return (try? FileManager.default.copyItem(at: url, to: dest)) != nil ? dest : nil
        case let image as UIImage:
            let dest = dir.appendingPathComponent("image.jpg")
            return (try? image.jpegData(compressionQuality: 0.9)?.write(to: dest)) != nil ? dest : nil
        case let data as Data:
            let ext = UTType(identifier)?.preferredFilenameExtension ?? "bin"
            let dest = dir.appendingPathComponent("file.\(ext)")
            return (try? data.write(to: dest)) != nil ? dest : nil
        default:
            return nil
        }
    }
}

struct ShareView: View {
    @Bindable var model: ShareModel
    @State private var qr: QRPayload?
    @State private var toast: String?
    @AppStorage("shareHours") private var hours = 24

    var body: some View {
        TermPage(path: "share") {
            switch model.phase {
            case .loading: StatusLine(kind: .running, text: "reading…")
            case .empty: StatusLine(kind: .error, text: "nothing to handle")
            case .ready: content
            }
        }
        .overlay(alignment: .topTrailing) {
            Button("done") { model.close() }
                .buttonStyle(.term)
                .padding(16)
        }
        .termToast($toast)
        .sheet(item: $qr) { QRSheet(payload: $0) }
    }

    @ViewBuilder
    private var content: some View {
        if let image = model.image {
            ImagePreview(image: image)
        }
        if model.isScanning {
            StatusLine(kind: .running, text: "ocr…")
        }

        if model.hasWiFi {
            TermBlock(label: "wifi") {
                TermField(key: "ssid", text: $model.ssid)
                TermDivider()
                TermField(key: "pw", text: $model.password)
                HStack(spacing: 8) {
                    Button("copy pw") { copy(model.password) }
                        .buttonStyle(.termPrimary)
                    Button { qr = .wifi(ssid: model.ssid, password: model.password) } label: {
                        Label("qr", systemImage: "qrcode")
                    }
                    .buttonStyle(.term)
                }
            }
        }

        ForEach($model.accounts) { $account in
            TermBlock(label: "acct") {
                TermField(key: "bank", text: optional($account, \.bank), placeholder: "?")
                TermDivider()
                TermField(key: "no", text: $account.number, keyboard: .numbersAndPunctuation)
                TermDivider()
                TermField(key: "holder", text: optional($account, \.holder), placeholder: "?")
                HStack(spacing: 8) {
                    Button("copy") {
                        copy([account.bank, account.digits].compactMap { $0 }.joined(separator: " "))
                    }
                    .buttonStyle(.termPrimary)
                    Button("digits") { copy(account.digits) }
                        .buttonStyle(.term)
                    Button { qr = .account(account) } label: { Image(systemName: "qrcode") }
                        .buttonStyle(.term)
                }
            }
        }

        if let link = model.link {
            TermBlock(label: "link") {
                Text(link.absoluteString)
                    .font(Term.mono(13))
                    .lineLimit(3)
                Button {
                    qr = .link(link, title: link.host() ?? link.absoluteString, subtitle: nil)
                } label: {
                    Label("qr", systemImage: "qrcode")
                }
                .buttonStyle(.termPrimary)
            }
        }

        if let text = model.text, model.accounts.isEmpty {
            TermBlock(label: "text") {
                Text(text)
                    .font(Term.mono(13))
                    .lineLimit(6)
                HStack(spacing: 8) {
                    Button { qr = .text(text) } label: { Label("qr", systemImage: "qrcode") }
                        .buttonStyle(.termPrimary)
                    Button("copy") { copy(text) }
                        .buttonStyle(.term)
                }
            }
        }

        if let file = model.file {
            TermBlock(label: "file") {
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.lastPathComponent)
                        .font(Term.mono(14))
                        .lineLimit(1)
                    Text(ByteCountFormatter.string(fromByteCount: model.fileSize, countStyle: .file))
                        .font(Term.mono(11))
                        .foregroundStyle(Term.muted)
                }
                HStack(spacing: 10) {
                    Text("ttl").font(Term.mono(13)).foregroundStyle(Term.muted)
                    TermChoice(options: [("1h", 1), ("6h", 6), ("1d", 24), ("2d", 48)], selection: $hours)
                }
                if let progress = model.progress {
                    UploadProgress(value: progress)
                } else if let error = model.uploadError {
                    StatusLine(kind: .error, text: error)
                }
                Button {
                    Task {
                        if let shared = await model.upload(hours: hours) {
                            qr = .link(shared.url, title: shared.name, subtitle: nil)
                        }
                    }
                } label: {
                    Label("upload → qr", systemImage: "qrcode")
                }
                .buttonStyle(.termPrimary)
                .disabled(model.progress != nil)
            }
        }
    }

    private func copy(_ string: String) {
        UIPasteboard.general.string = string
        toast = "✓ copied"
    }

    private func optional(
        _ account: Binding<AccountCandidate>, _ keyPath: WritableKeyPath<AccountCandidate, String?>
    ) -> Binding<String> {
        Binding(
            get: { account.wrappedValue[keyPath: keyPath] ?? "" },
            set: { account.wrappedValue[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }
}
