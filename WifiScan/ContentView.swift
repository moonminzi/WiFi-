import SwiftUI

struct ContentView: View {
    @State private var model = ScanModel()
    @AppStorage("autoJoin") private var autoJoin = true

    var body: some View {
        TermPage(path: "wifi") {
            ImageSourceBar(onImage: { scan($0) })

            if let image = model.image {
                ImagePreview(image: image)
            }

            switch model.status {
            case .scanning: StatusLine(kind: .running, text: "ocr…")
            case .notFound: StatusLine(kind: .error, text: "no ssid found")
            default: EmptyView()
            }

            TermBlock(label: "net") {
                TermField(key: "ssid", text: $model.ssid, placeholder: "—")
                AlternativeChips(values: model.ssidAlternatives) { model.ssid = $0 }
                TermDivider()
                TermField(key: "pw", text: $model.password, placeholder: "—")
                if !model.password.isEmpty {
                    AmbiguousCharacterEditor(text: $model.password)
                }
                AlternativeChips(values: model.passwordAlternatives) { model.password = $0 }
            }

            Button {
                Task { await model.join() }
            } label: {
                if model.status == .joining {
                    ProgressView().tint(Term.bg)
                } else {
                    Label("connect", systemImage: "wifi")
                }
            }
            .buttonStyle(.termPrimary)
            .disabled(!model.canJoin)

            Toggle(isOn: $autoJoin) {
                Text("--auto-join")
                    .font(Term.mono(13))
                    .foregroundStyle(Term.muted)
            }
            .tint(Term.green)

            switch model.status {
            case .joined(let ssid): StatusLine(kind: .ok, text: "joined \(ssid)")
            case .failed(let message): StatusLine(kind: .error, text: message)
            default: EmptyView()
            }
        }
    }

    private func scan(_ image: UIImage) {
        Task { await model.load(image, autoJoin: autoJoin) }
    }
}

/// OCR이 함께 내놓은 다른 후보들. 누르면 그 값으로 바꾼다.
private struct AlternativeChips: View {
    let values: [String]
    let onSelect: (String) -> Void

    var body: some View {
        if !values.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text("alt")
                        .foregroundStyle(Term.muted)
                        .frame(width: 56, alignment: .leading)
                    ForEach(values, id: \.self) { value in
                        Button(value) { onSelect(value) }
                            .foregroundStyle(Term.blue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Term.border))
                            .buttonStyle(.plain)
                    }
                }
                .font(Term.mono(12))
            }
        }
    }
}

/// 비밀번호를 한 글자씩 보여주고, 헷갈리는 글자(노란색)를 누르면 비슷한 글자로 순환시킨다.
struct AmbiguousCharacterEditor: View {
    @Binding var text: String

    private static let groups: [[Character]] = [
        ["0", "O", "D", "Q", "o"],
        ["1", "l", "I", "i", "|"],
        ["5", "S", "s"],
        ["2", "Z", "z"],
        ["8", "B"],
        ["6", "G", "b"],
        ["9", "g", "q"],
    ]

    static func group(for c: Character) -> [Character]? {
        groups.first { $0.contains(c) }
    }

    var body: some View {
        let chars = Array(text)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(chars.indices, id: \.self) { i in
                    let c = chars[i]
                    if let group = Self.group(for: c) {
                        Button {
                            var updated = chars
                            let next = (group.firstIndex(of: c)! + 1) % group.count
                            updated[i] = group[next]
                            text = String(updated)
                        } label: {
                            cell(c, color: Term.amber)
                        }
                        .buttonStyle(.plain)
                    } else {
                        cell(c, color: Term.text)
                    }
                }
            }
        }
    }

    private func cell(_ c: Character, color: Color) -> some View {
        Text(String(c))
            .font(Term.mono(18, .semibold))
            .foregroundStyle(color)
            .frame(minWidth: 26, minHeight: 36)
            .background(color == Term.amber ? Term.amber.opacity(0.12) : Term.bg, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color == Term.amber ? Term.amber.opacity(0.6) : Term.border))
    }
}
