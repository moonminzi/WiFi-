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
            subtitle: "카메라로 찍으면 바로 연결돼요",
            content: content,
            copyText: password.isEmpty ? ssid : password)
    }

    static func link(_ url: URL, title: String, subtitle: String?) -> QRPayload {
        QRPayload(title: title, subtitle: subtitle, content: url.absoluteString, copyText: url.absoluteString)
    }

    static func text(_ text: String) -> QRPayload {
        QRPayload(title: "텍스트", subtitle: nil, content: text, copyText: text)
    }

    static func account(_ account: AccountCandidate) -> QRPayload {
        let text = [account.bank, account.number, account.holder].compactMap { $0 }.joined(separator: " ")
        return QRPayload(
            title: [account.bank, account.number].compactMap { $0 }.joined(separator: " "),
            subtitle: account.holder.map { "예금주 \($0)" },
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
    @State private var copied = false
    @State private var originalBrightness: CGFloat?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let image = QRCode.image(for: payload.content) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(16)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
                        .frame(maxWidth: 320)
                } else {
                    ContentUnavailableView(
                        "QR로 만들기엔 너무 길어요",
                        systemImage: "exclamationmark.triangle",
                        description: Text("약 2,900바이트(한글 약 900자)까지 들어가요."))
                }

                VStack(spacing: 4) {
                    Text(payload.title)
                        .font(.title3.bold())
                        .textSelection(.enabled)
                    if let subtitle = payload.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.center)

                HStack {
                    Button {
                        UIPasteboard.general.string = payload.copyText
                        copied = true
                    } label: {
                        Label(copied ? "복사됨" : "복사", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    ShareLink(item: payload.copyText) {
                        Label("공유", systemImage: "square.and.arrow.up")
                    }
                }
                .buttonStyle(.bordered)

                Spacer()
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
        .onAppear {
            guard let screen = Self.screen else { return }
            originalBrightness = screen.brightness
            screen.brightness = 1
        }
        .onDisappear {
            if let originalBrightness { Self.screen?.brightness = originalBrightness }
        }
    }

    private static var screen: UIScreen? {
        (UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene)?
            .screen
    }
}
