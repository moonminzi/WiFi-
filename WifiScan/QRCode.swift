import CoreImage.CIFilterBuiltins
import SwiftUI

/// QR로 보여줄 내용. `content`가 QR에 들어가고, `copyText`는 복사·공유 버튼이 쓴다.
struct QRPayload: Identifiable {
    let id = UUID()
    var title: String
    var subtitle: String?
    var content: String
    var copyText: String

    /// 아이폰·안드로이드 기본 카메라로 찍으면 바로 "네트워크에 연결" 버튼이 뜨는 형식
    static func wifi(ssid: String, password: String) -> QRPayload {
        let ssid = ssid.trimmingCharacters(in: .whitespaces)
        let content = password.isEmpty
            ? "WIFI:T:nopass;S:\(escape(ssid));;"
            : "WIFI:T:WPA;S:\(escape(ssid));P:\(escape(password));;"
        return QRPayload(
            title: ssid,
            subtitle: password.isEmpty ? "open" : "wpa",
            content: content,
            copyText: password.isEmpty ? ssid : password)
    }

    static func link(_ url: URL, title: String, subtitle: String?) -> QRPayload {
        QRPayload(title: title, subtitle: subtitle, content: url.absoluteString, copyText: url.absoluteString)
    }

    static func text(_ text: String) -> QRPayload {
        QRPayload(title: "text", subtitle: "\(text.utf8.count) B", content: text, copyText: text)
    }

    static func account(_ account: AccountCandidate) -> QRPayload {
        let text = [account.bank, account.number, account.holder].compactMap { $0 }.joined(separator: " ")
        return QRPayload(
            title: [account.bank, account.number].compactMap { $0 }.joined(separator: " "),
            subtitle: account.holder,
            content: text,
            copyText: text)
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        for c in s {
            if "\\;,:\"".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }
}

enum QRCode {
    /// 내용이 너무 길면(약 2,900바이트 초과) nil
    static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// QR을 크게 보여주는 시트. 보는 동안 화면을 최대 밝기로 올려서 상대가 잘 찍히게 한다.
struct QRSheet: View {
    let payload: QRPayload
    @Environment(\.dismiss) private var dismiss
    @State private var toast: String?
    @State private var originalBrightness: CGFloat?
    @State private var screen: UIScreen?

    var body: some View {
        TermPage(path: "qr") {
            if let image = QRCode.image(for: payload.content) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(14)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
                    .frame(maxWidth: 300)
                    .frame(maxWidth: .infinity)
            } else {
                StatusLine(kind: .error, text: "payload > 2900 B")
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(payload.title)
                    .font(Term.mono(17, .bold))
                    .textSelection(.enabled)
                if let subtitle = payload.subtitle {
                    Text(subtitle)
                        .font(Term.mono(12))
                        .foregroundStyle(Term.muted)
                }
            }

            TermBlock(label: "payload") {
                Text(payload.content)
                    .font(Term.mono(12))
                    .foregroundStyle(Term.muted)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                Button {
                    UIPasteboard.general.string = payload.copyText
                    toast = "✓ copied"
                } label: {
                    Label("copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.termPrimary)
                ShareLink(item: payload.copyText) {
                    Label("share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.term)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button("esc") { dismiss() }
                .buttonStyle(.term)
                .padding(16)
        }
        .termToast($toast)
        .presentationBackground(Term.bg)
        .background(ScreenReader { screen = $0 })
        .onChange(of: screen) { _, screen in
            guard let screen, originalBrightness == nil else { return }
            originalBrightness = screen.brightness
            screen.brightness = 1
        }
        .onDisappear {
            if let originalBrightness { screen?.brightness = originalBrightness }
        }
    }
}

/// 이 뷰가 올라간 창의 화면을 알려준다. 앱 확장에서는 UIApplication.shared를 못 써서 창에서 직접 찾는다.
private struct ScreenReader: UIViewRepresentable {
    let onScreen: (UIScreen) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onScreen = onScreen
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {}

    final class ProbeView: UIView {
        var onScreen: ((UIScreen) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let screen = window?.windowScene?.screen { onScreen?(screen) }
        }
    }
}
