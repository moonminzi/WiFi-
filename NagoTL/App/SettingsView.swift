import NagoTLCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var library: Library
    @State private var key = ""
    @State private var saved = Keychain.apiKey
    @State private var checking = false
    @State private var check: (ok: Bool, text: String)?

    var body: some View {
        TermPage(path: "settings") {
            TermBlock(label: "claude api key") {
                if let saved {
                    StatusLine(kind: .ok, text: "저장됨 · …" + String(saved.suffix(6)))
                } else {
                    StatusLine(kind: .warn, text: "키가 없어요 — 번역하려면 필요해요")
                }
                TermField(key: "key", text: $key, placeholder: "sk-ant-…", secure: true)
                HStack(spacing: 8) {
                    Button {
                        Keychain.apiKey = key
                        saved = Keychain.apiKey
                        key = ""
                        Task { await verify() }
                    } label: { Label("저장", systemImage: "key") }
                        .buttonStyle(TermButtonStyle(kind: .primary))
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button { Task { await verify() } } label: { Label("확인", systemImage: "checkmark.shield") }
                        .buttonStyle(.term)
                        .disabled(saved == nil || checking)
                    if saved != nil {
                        Button {
                            Keychain.apiKey = nil
                            saved = nil
                            check = nil
                        } label: { Label("지우기", systemImage: "trash") }
                            .buttonStyle(.termDanger)
                    }
                }
                if checking { StatusLine(kind: .running, text: "확인 중") }
                if let check { StatusLine(kind: check.ok ? .ok : .error, text: check.text) }
                Text("console.anthropic.com → API Keys에서 만들어요. 키는 이 아이폰 키체인에만 저장되고 다른 곳에 보내지 않아요(번역 요청 때 Anthropic에만).")
                    .font(Term.mono(11.5))
                    .foregroundStyle(Term.muted)
            }

            TermBlock(label: "engine") {
                line("model", "Claude Opus 5.5")
                line("read", "그림 전체를 보고 세로쓰기·손글씨·효과음까지 읽음")
                line("translate", "앞 쪽 줄거리·용어집을 기억하며 자연스러운 한국어로")
                line("letter", "말풍선 모양을 찾아 원문만 지우고 한글을 모양대로 앉힘")
                line("photo", "사진 위 글자는 둘레 색으로 덮고 그 자리에")
                TermDivider()
                line("spent", library.totalUsage.costText + " (지금까지 모든 책)")
                line("price", "보통 한 쪽에 $0.03~0.10 (그림 크기·글 양에 따라)")
            }

            TermBlock(label: "tips") {
                Text("""
                • 뷰어를 열면 보고 있는 쪽과 다음 두 쪽을 먼저 번역해요.
                • 말풍선을 누르면 원문을 보고 번역을 고치거나 다른 표현을 받을 수 있어요.
                • 작품 설정의 메모에 등장인물·말투를 적어 두면 번역이 더 정확해져요.
                • 번역 중에는 앱을 켜 두세요(화면이 꺼지지 않게 해 둬요).
                """)
                .font(Term.mono(12))
                .foregroundStyle(Term.muted)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private func line(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(k).foregroundStyle(Term.key).frame(width: 74, alignment: .leading)
            Text(v).foregroundStyle(Term.text)
        }
        .font(Term.mono(12.5))
    }

    private func verify() async {
        guard let k = Keychain.apiKey else { return }
        checking = true
        check = nil
        let err = await ClaudeClient.checkKey(k)
        checking = false
        check = err == nil ? (true, "키가 맞아요") : (false, err!)
    }
}
