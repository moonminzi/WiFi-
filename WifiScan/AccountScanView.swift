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
        NavigationStack {
            Form {
                Section {
                    if let image = model.image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    ImageSourceBar(onImage: { image in Task { await model.load(image) } }) {
                        SourceButton(title: "글자 붙여넣기", systemImage: "text.badge.plus") {
                            if let text = UIPasteboard.general.string { model.load(text: text) }
                        }
                        .disabled(!pasteboardHasText)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    if model.isScanning {
                        Label("글자 읽는 중…", systemImage: "text.viewfinder")
                    } else if model.notFound {
                        Text("계좌번호를 찾지 못했어요. 더 가까이 찍거나, 글자를 복사해서 붙여넣어 보세요.")
                    } else if model.accounts.isEmpty {
                        Text("단톡방 캡처, 공지 사진, 복사한 메시지에서 은행과 계좌번호를 찾아요.")
                    }
                }

                ForEach($model.accounts) { $account in
                    AccountSection(account: $account) { action in
                        perform(action, on: account)
                    }
                }
            }
            .navigationTitle("계좌번호")
            .sheet(item: $qr) { QRSheet(payload: $0) }
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast)
                        .font(.subheadline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.default, value: toast)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { pasteboardHasText = UIPasteboard.general.hasStrings }
            }
        }
    }

    private func perform(_ action: AccountSection.Action, on account: AccountCandidate) {
        // 토스·은행 앱은 "은행 계좌번호"가 복사돼 있으면 송금 화면에서 자동으로 잡아준다
        let withBank = [account.bank, account.digits].compactMap { $0 }.joined(separator: " ")
        switch action {
        case .copy:
            UIPasteboard.general.string = withBank
            show("복사했어요. 송금 앱에서 붙여넣으세요")
        case .copyDigits:
            UIPasteboard.general.string = account.digits
            show("숫자만 복사했어요")
        case .qr:
            qr = .account(account)
        case .open(let app):
            UIPasteboard.general.string = withBank
            guard let url = URL(string: app.urlScheme) else { return }
            openURL(url) { accepted in
                show(accepted ? "복사해 뒀어요. 송금 화면에서 붙여넣으세요" : "\(app.title) 앱이 없어요")
            }
        }
    }

    private func show(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if toast == message { toast = nil }
        }
    }
}

private struct AccountSection: View {
    enum Action {
        case copy, copyDigits, qr
        case open(BankApp)
    }

    enum BankApp: CaseIterable {
        case toss, kakaoBank

        var title: String {
            switch self {
            case .toss: "토스"
            case .kakaoBank: "카카오뱅크"
            }
        }

        var urlScheme: String {
            switch self {
            case .toss: "supertoss://"
            case .kakaoBank: "kakaobank://"
            }
        }
    }

    @Binding var account: AccountCandidate
    let onAction: (Action) -> Void

    var body: some View {
        Section {
            HStack {
                TextField("은행", text: optional(\.bank))
                Menu {
                    ForEach(AccountParser.bankNames, id: \.self) { name in
                        Button(name) { account.bank = name }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                }
            }
            TextField("계좌번호", text: $account.number)
                .font(.title3.monospaced())
                .keyboardType(.numbersAndPunctuation)
            TextField("예금주 (선택)", text: optional(\.holder))

            HStack {
                Button { onAction(.copy) } label: { Label("복사", systemImage: "doc.on.doc") }
                Button { onAction(.copyDigits) } label: { Text("숫자만") }
                Button { onAction(.qr) } label: { Label("QR", systemImage: "qrcode") }
                Menu {
                    ForEach(BankApp.allCases, id: \.self) { app in
                        Button(app.title) { onAction(.open(app)) }
                    }
                } label: {
                    Label("송금 앱", systemImage: "arrow.up.forward.app")
                }
            }
            .buttonStyle(.bordered)
            .labelStyle(.titleAndIcon)
            .font(.subheadline)
        }
    }

    private func optional(_ keyPath: WritableKeyPath<AccountCandidate, String?>) -> Binding<String> {
        Binding(
            get: { account[keyPath: keyPath] ?? "" },
            set: { account[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }
}
