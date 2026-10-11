import NagoTLCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var library: Library
    @State private var key = ""
    @State private var saved = Keychain.apiKey
    @State private var checking = false
    @State private var check: (ok: Bool, text: String)?
    @AppStorage(Budget.limitKey) private var budget = 5.0
    @AppStorage(Budget.spentKey) private var spent = 0.0
    @State private var budgetText = ""
    @State private var confirmReset = false

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

            TermBlock(label: "budget") {
                let left = max(0, budget - spent)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("한도").foregroundStyle(Term.muted).frame(width: 56, alignment: .leading)
                    TextField("5", text: $budgetText)
                        .keyboardType(.decimalPad)
                        .frame(width: 80)
                        .onSubmit { applyBudget() }
                    Text("달러").foregroundStyle(Term.muted)
                    Spacer()
                    Button("적용") { applyBudget() }
                        .buttonStyle(.term)
                }
                .font(Term.mono(15))
                line("spent", Usage.money(spent) + " / " + Usage.money(budget))
                line("left", Usage.money(left) + String(format: " · 기본 번역으로 약 %d쪽",
                                                          Int(left / ClaudeAPI.Engine.standard.estimatedPageCost)))
                Text("이 한도를 넘으면 번역을 멈춰요. 실제 잔액은 Anthropic 콘솔(Billing)이 기준이고, 여기 숫자는 앱이 센 어림값이에요.")
                    .font(Term.mono(11.5))
                    .foregroundStyle(Term.muted)
                Button { confirmReset = true } label: { Label("쓴 돈 0으로(새로 충전했을 때)", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(.term)
            }

            TermBlock(label: "engine") {
                line("기본", "Claude Haiku 5.5 — 한 쪽에 약 0.3센트")
                line("고급", "Claude Opus 5.5 — 한 쪽에 약 12센트, 뷰어 ⋯ 메뉴에서 그 쪽만")
                line("read", "그림 전체를 보고 세로쓰기·손글씨·효과음까지 읽음")
                line("translate", "앞 쪽 줄거리·용어집을 기억하며 자연스러운 한국어로")
                line("letter", "말풍선 모양을 찾아 원문만 지우고 한글을 모양대로 앉힘")
                line("art", "말풍선 없이 그림 위에 쓴 글자는 글자·테두리 색만 골라 지우고 그림을 이어 그린 뒤, 같은 색·세로쓰기로")
                line("photo", "사진 위 글자는 둘레 색으로 덮고 그 자리에")
                TermDivider()
                line("books", library.totalUsage.costText + " (지금 서재에 있는 책들)")
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
        .onAppear { budgetText = String(format: "%g", budget) }
        .confirmationDialog("앱이 센 쓴 돈을 0으로 할까요?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("0으로") { spent = 0 }
        }
    }

    private func applyBudget() {
        let v = Double(budgetText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) ?? budget
        budget = max(0.5, min(1000, v))
        budgetText = String(format: "%g", budget)
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
