import SwiftUI

/// 터미널 느낌의 다크 테마. 색은 GitHub Dark 팔레트를 따른다.
enum Term {
    static let bg = Color(hex: 0x0D1117)
    static let surface = Color(hex: 0x161B22)
    static let border = Color(hex: 0x30363D)
    static let text = Color(hex: 0xE6EDF3)
    static let muted = Color(hex: 0x7D8590)
    static let green = Color(hex: 0x3FB950)
    static let amber = Color(hex: 0xD29922)
    static let red = Color(hex: 0xF85149)
    static let blue = Color(hex: 0x58A6FF)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - 화면 틀

/// `~/wifi $▌` 머리줄이 붙은 스크롤 화면
struct TermPage<Content: View>: View {
    let path: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 0) {
                    Text("~/").foregroundStyle(Term.muted)
                    Text(path).foregroundStyle(Term.green)
                    Text(" $ ").foregroundStyle(Term.muted)
                    BlinkingCursor()
                }
                .font(Term.mono(22, .bold))
                .padding(.top, 8)

                content
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Term.bg.ignoresSafeArea())
        .foregroundStyle(Term.text)
        .tint(Term.green)
    }
}

private struct BlinkingCursor: View {
    @State private var visible = true

    var body: some View {
        Rectangle()
            .fill(Term.green)
            .frame(width: 11, height: 22)
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.55).repeatForever()) { visible = false }
            }
    }
}

/// `// label` 주석 머리가 달린 테두리 상자
struct TermBlock<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("// \(label)")
                .font(Term.mono(12))
                .foregroundStyle(Term.muted)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Term.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Term.border, lineWidth: 1))
        }
    }
}

// MARK: - 입력

/// `ssid  U+Net…` 처럼 왼쪽에 키, 오른쪽에 값
struct TermField: View {
    let key: String
    @Binding var text: String
    var placeholder = ""
    var secure = false
    var keyboard: UIKeyboardType = .default

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key)
                .foregroundStyle(Term.muted)
                .frame(width: 56, alignment: .leading)
            Group {
                if secure {
                    SecureField("", text: $text, prompt: prompt)
                } else {
                    TextField("", text: $text, prompt: prompt)
                }
            }
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
        .font(Term.mono(15))
    }

    private var prompt: Text {
        Text(placeholder).foregroundStyle(Term.muted.opacity(0.5))
    }
}

/// 상자 안 줄 사이 구분선
struct TermDivider: View {
    var body: some View {
        Rectangle().fill(Term.border).frame(height: 1)
    }
}

// MARK: - 버튼

struct TermButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, danger }
    var kind: Kind = .secondary
    var fill = false

    func makeBody(configuration: Configuration) -> some View {
        TermButtonBody(configuration: configuration, kind: kind, fill: fill)
    }

    private struct TermButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        let fill: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(Term.mono(14, .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: fill ? .infinity : nil)
                .foregroundStyle(foreground)
                .background(background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(stroke, lineWidth: 1))
                .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }

        private var accent: Color {
            switch kind {
            case .primary: Term.green
            case .secondary: Term.text
            case .danger: Term.red
            }
        }
        private var foreground: Color { kind == .primary ? Term.bg : accent }
        private var background: Color { kind == .primary ? Term.green : Term.surface }
        private var stroke: Color { kind == .primary ? Term.green : Term.border }
    }
}

extension ButtonStyle where Self == TermButtonStyle {
    static var term: TermButtonStyle { TermButtonStyle() }
    static var termPrimary: TermButtonStyle { TermButtonStyle(kind: .primary, fill: true) }
    static var termDanger: TermButtonStyle { TermButtonStyle(kind: .danger) }
}

/// 여러 값 중 하나를 고르는 `[1h] 6h 1d 2d` 형태의 선택 줄
struct TermChoice<Value: Hashable>: View {
    let options: [(label: String, value: Value)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = option.value == selection
                Button(option.label) { selection = option.value }
                    .font(Term.mono(13, selected ? .bold : .regular))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .foregroundStyle(selected ? Term.bg : Term.muted)
                    .background(selected ? Term.green : .clear, in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? Term.green : Term.border))
                    .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 상태 표시

struct StatusLine: View {
    enum Kind { case running, ok, warn, error }
    let kind: Kind
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(symbol).foregroundStyle(color)
            Text(text).foregroundStyle(kind == .running ? Term.muted : color)
            if kind == .running { ProgressView().controlSize(.mini).tint(Term.muted) }
        }
        .font(Term.mono(13))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var symbol: String {
        switch kind {
        case .running: ">"
        case .ok: "✓"
        case .warn: "!"
        case .error: "✗"
        }
    }

    private var color: Color {
        switch kind {
        case .running: Term.muted
        case .ok: Term.green
        case .warn: Term.amber
        case .error: Term.red
        }
    }
}

/// 화면 아래에 잠깐 떴다 사라지는 한 줄 알림
struct TermToast: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message {
                Text(message)
                    .font(Term.mono(13))
                    .foregroundStyle(Term.green)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Term.surface, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Term.green.opacity(0.5)))
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: message) {
                        try? await Task.sleep(for: .seconds(2))
                        if self.message == message { self.message = nil }
                    }
            }
        }
        .animation(.easeOut(duration: 0.2), value: message)
    }
}

extension View {
    func termToast(_ message: Binding<String?>) -> some View {
        modifier(TermToast(message: message))
    }
}

/// 찍은 사진 미리보기
struct ImagePreview: View {
    let image: UIImage

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: 200)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Term.border))
    }
}

/// `[██████░░░░░░] 52%` 형태의 진행률
struct UploadProgress: View {
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
