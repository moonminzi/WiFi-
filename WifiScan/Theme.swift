import SwiftUI
import UIKit

/// 터미널 느낌의 다크 테마. 색과 글꼴(JetBrains Mono)은 대시보드 사이트와 같다.
enum Term {
    static let bg = Color(hex: 0x0A0D0A)
    static let surface = Color(hex: 0x0D110D)   // 창 안쪽
    static let chrome = Color(hex: 0x141A14)    // 창 제목 줄
    static let border = Color(hex: 0x1F2A1F)
    static let text = Color(hex: 0xC9D4C5)
    static let muted = Color(hex: 0x5F6F5F)
    static let green = Color(hex: 0x4ADE80)
    static let amber = Color(hex: 0xFBBF24)
    static let red = Color(hex: 0xF87171)
    static let key = Color(hex: 0x67E8F9)       // 이름/키
    static let path = Color(hex: 0x93C5FD)      // 프롬프트 경로
    static let num = Color(hex: 0xE7ECE5)       // 숫자
    static let track = Color(hex: 0x1C261C)     // 막대 빈 칸
    static let dot = Color(hex: 0x3A463A)       // 창 제목 줄 점

    /// 앱에 넣은 JetBrains Mono가 등록됐는지. 안 됐으면 시스템 고정폭 글꼴로 대신한다.
    static let hasJetBrains = UIFont(name: "JetBrainsMono-Regular", size: 12) != nil

    static func fontName(_ weight: Font.Weight) -> String {
        switch weight {
        case .bold, .heavy, .black: return "JetBrainsMono-Bold"
        case .semibold, .medium: return "JetBrainsMono-SemiBold"
        default: return "JetBrainsMono-Regular"
        }
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        hasJetBrains ? .custom(fontName(weight), fixedSize: size) : .system(size: size, weight: weight, design: .monospaced)
    }

    static func uiMono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> UIFont {
        UIFont(name: fontName(weight), size: size) ?? .monospacedSystemFont(ofSize: size, weight: .medium)
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

/// `~/vpn $▌` 머리줄이 붙은 스크롤 화면
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

struct BlinkingCursor: View {
    var width: CGFloat = 11
    var height: CGFloat = 22
    @State private var visible = true

    var body: some View {
        Rectangle()
            .fill(Term.green)
            .frame(width: width, height: height)
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

// MARK: - 창

/// 대시보드 사이트와 같은 터미널 창: 점 세 개 제목 줄 + 안쪽 내용
struct TermWindow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(Term.dot).frame(width: 10, height: 10)
                }
                Text(title)
                    .font(Term.mono(11.5))
                    .foregroundStyle(Term.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Term.chrome)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Term.border).frame(height: 1)
            }

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Term.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Term.border, lineWidth: 1))
    }
}
