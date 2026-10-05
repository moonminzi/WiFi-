import SwiftUI

@MainActor
@Observable
final class AccountScanModel {
    var image: UIImage?
    var accounts: [AccountCandidate] = []
    var isScanning = false
    var notFound = false

    func load(_ image: UIImage) async {
        self.image = image
        isScanning = true
        notFound = false
        let text = await TextRecognizer.recognizeText(in: image)
        isScanning = false
        apply(text)
    }

    func load(text: String) {
        image = nil
        apply(text)
    }

    private func apply(_ text: String) {
        accounts = AccountParser.parse(text)
        notFound = accounts.isEmpty
    }
}

struct AccountScanView: View {
    @State private var model = AccountScanModel()
    @State private var qr: QRPayload?
    @State private var toast: String?
    @State private var pasteboardHasText = UIPasteboard.general.hasStrings
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TermPage(path: "acct") {
            ImageSourceBar(onImage: { image in Task { await model.load(image) } }) {
                Button {
                    if let text = UIPasteboard.general.string { model.load(text: text) }
                } label: {
                    Label("txt", systemImage: "text.alignleft")
                }
                .disabled(!pasteboardHasText)
            }

            if let image = model.image {
                ImagePreview(image: image)
            }

            if model.isScanning {
                StatusLine(kind: .running, text: "ocr…")
            } else if model.notFound {
                StatusLine(kind: .error, text: "no account found")
            } else if !model.accounts.isEmpty {
                StatusLine(kind: .ok, text: "\(model.accounts.count) found")
            }

            ForEach($model.accounts) { $account in
                let index = model.accounts.firstIndex { $0.id == account.id } ?? 0
                AccountBlock(index: index, account: $account) { action in
                    perform(action, on: account)
                }
            }
        }
        .termToast($toast)
        .sheet(item: $qr) { QRSheet(payload: $0) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { pasteboardHasText = UIPasteboard.general.hasStrings }
        }
    }

    private func perform(_ action: AccountBlock.Action, on account: AccountCandidate) {
        // 토스·은행 앱은 "은행 계좌번호"가 복사돼 있으면 송금 화면에서 자동으로 잡아준다
        let withBank = [account.bank, account.digits].compactMap { $0 }.joined(separator: " ")
        switch action {
        case .copy:
            UIPasteboard.general.string = withBank
            toast = "✓ copied: \(withBank)"
        case .copyDigits:
            UIPasteboard.general.string = account.digits
            toast = "✓ copied: \(account.digits)"
        case .qr:
            qr = .account(account)
        case .open(let app):
            UIPasteboard.general.string = withBank
            guard let url = URL(string: app.urlScheme) else { return }
            openURL(url) { accepted in
                toast = accepted ? "✓ copied → \(app.title)" : "✗ \(app.title) not installed"
            }
        }
    }
}

private struct AccountBlock: View {
    enum Action {
        case copy, copyDigits, qr
        case open(BankApp)
    }

    enum BankApp: CaseIterable {
        case toss, kakaoBank

        var title: String {
            switch self {
            case .toss: "toss"
            case .kakaoBank: "kakaobank"
            }
        }

        var urlScheme: String {
            switch self {
            case .toss: "supertoss://"
            case .kakaoBank: "kakaobank://"
            }
        }
    }

    let index: Int
    @Binding var account: AccountCandidate
    let onAction: (Action) -> Void

    var body: some View {
        TermBlock(label: String(format: "%02d", index + 1)) {
            HStack {
                TermField(key: "bank", text: optional(\.bank), placeholder: "?")
                Menu {
                    ForEach(AccountParser.bankNames, id: \.self) { name in
                        Button(name) { account.bank = name }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(Term.mono(13))
                        .foregroundStyle(Term.muted)
                        .frame(width: 32, height: 28)
                }
            }
            TermDivider()
            TermField(key: "no", text: $account.number, keyboard: .numbersAndPunctuation)
            TermDivider()
            TermField(key: "holder", text: optional(\.holder), placeholder: "?")

            HStack(spacing: 8) {
                Button("copy") { onAction(.copy) }
                    .buttonStyle(.termPrimary)
                Button("digits") { onAction(.copyDigits) }
                Button { onAction(.qr) } label: { Image(systemName: "qrcode") }
                Menu {
                    ForEach(BankApp.allCases, id: \.self) { app in
                        Button(app.title) { onAction(.open(app)) }
                    }
                } label: {
                    Text("open ▾")
                }
            }
            .buttonStyle(.term)
            .menuStyle(.button)
        }
    }

    private func optional(_ keyPath: WritableKeyPath<AccountCandidate, String?>) -> Binding<String> {
        Binding(
            get: { account[keyPath: keyPath] ?? "" },
            set: { account[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }
}
