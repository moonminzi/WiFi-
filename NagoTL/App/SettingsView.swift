import NagoTLCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var library: Library
    @AppStorage(Budget.limitKey) private var budget = 5.0
    @AppStorage(Budget.spentKey) private var spent = 0.0
    @AppStorage(Pipeline.sfxKey) private var translateSFX = true
    @AppStorage(FontBook.dialogueKey) private var dialogueFont: FontBook.Choice = .jua
    @AppStorage(FontBook.sfxKey) private var sfxFont: FontBook.Choice = .blackHanSans
    // 고른 AI가 바뀌면 아래 요약도 다시 그리게
    @AppStorage(AISettings.primaryKey) private var primary: Provider = .claude
    @AppStorage(AISettings.fallbackKey) private var fallback = ""
    @State private var budgetText = ""
    @State private var confirmReset = false

    var body: some View {
        TermPage(path: "settings") {
            AISection()

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
                line("left", leftLine(left))
                Text("이 한도를 넘으면 번역을 멈춰요. 실제 잔액은 각 AI 회사 콘솔(결제 화면)이 기준이고, 여기 숫자는 앱이 센 어림값이에요.")
                    .font(Term.mono(11.5))
                    .foregroundStyle(Term.muted)
                Button { confirmReset = true } label: { Label("쓴 돈 0으로(새로 충전했을 때)", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(.term)
            }

            TermBlock(label: "font") {
                Text("대사·나레이션").font(Term.mono(12)).foregroundStyle(Term.key)
                ForEach(FontBook.dialogueOptions) { c in
                    fontRow(c, selected: dialogueFont == c, sample: "잘됐네요~ 오늘부터 너도 원숭이야!") { dialogueFont = c }
                }
                TermDivider()
                Text("효과음·추임새").font(Term.mono(12)).foregroundStyle(Term.key)
                ForEach(FontBook.sfxOptions) { c in
                    fontRow(c, selected: sfxFont == c, sample: "히죽히죽♥ 덜컥!!") { sfxFont = c }
                }
                Text("간판·사진 속 글자는 반듯한 시스템 고딕으로 써요. 바꾼 뒤 이미 번역한 쪽은 책 화면 더보기 → 모두 다시 그리기(무료).")
                    .font(Term.mono(11.5))
                    .foregroundStyle(Term.muted)
            }

            TermBlock(label: "sfx") {
                TermChoice(options: [(label: "같은 모양으로 번역", value: true), (label: "원문 그대로", value: false)],
                           selection: $translateSFX)
                Text("효과음·추임새(ニヤニヤ♥, ガタッ 같은 것)를 원래 색·테두리·세로쓰기 그대로 한글로 바꿔요. 깔끔하게 바꿀 자신이 없으면 그건 원문 그대로 둬요. '원문 그대로'면 늘 손대지 않아요. 어느 쪽이든 그 자리를 누르면 번역을 볼 수 있어요.")
                    .font(Term.mono(11.5))
                    .foregroundStyle(Term.muted)
                Text("이미 번역한 쪽은 책 화면 더보기 → 모두 다시 그리기(무료, 다시 번역하지 않음)로 바뀐 설정·새 그리기 방식을 적용해요.")
                    .font(Term.mono(11.5))
                    .foregroundStyle(Term.muted)
            }

            TermBlock(label: "engine") {
                line("기본", engineLine(.standard))
                line("고급", engineLine(.premium) + ", 뷰어 ⋯ 메뉴에서 그 쪽만")
                line("대체", fallbackLine)
                line("read", "그림 전체를 보고 세로쓰기·손글씨·효과음까지 읽음")
                line("translate", "앞 쪽 줄거리·용어집을 기억하며 자연스러운 한국어로")
                line("letter", "말풍선 모양을 찾아 원문만 지우고 한글을 모양대로 앉힘")
                line("art", "말풍선 없이 그림 위에 쓴 글자는 글자·테두리 색만 골라 지우고 그림을 이어 그린 뒤, 같은 색·세로쓰기로")
                line("photo", "사진 위 글자는 둘레 색으로 덮고 그 자리에(그림·사진 결이면 둘레 조각으로 메움)")
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

    /// 글꼴 하나(그 글꼴로 쓴 보기 글 + 고름 표시)
    private func fontRow(_ c: FontBook.Choice, selected: Bool, sample: String,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Term.green : Term.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.label).font(Term.mono(11.5)).foregroundStyle(Term.muted)
                    Text(sample)
                        .font(c.postScript.map { Font.custom($0, size: 20) } ?? .system(size: 20, weight: .bold))
                        .foregroundStyle(Term.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func leftLine(_ left: Double) -> String {
        let perPage = AISettings.estimatedPageCost()
        guard perPage > 0 else { return "\(Usage.money(left)) · 지금 AI는 무료 등급" }
        return "\(Usage.money(left)) · 기본 번역으로 약 \(Int(left / perPage))쪽"
    }

    private func engineLine(_ tier: ClaudeAPI.Engine) -> String {
        let name = AISettings.displayName(primary, tier: tier)
        let cost = Usage.money(AISettings.estimatedPageCost(tier: tier))
        return "\(primary.label) \(name) — 한 쪽에 약 \(cost)"
    }

    private var fallbackLine: String {
        guard let p = Provider(rawValue: fallback), p != primary else { return "없음" }
        return "\(p.label) — 기본이 거절·오류면 이걸로 다시"
    }

    private func line(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(k).foregroundStyle(Term.key).frame(width: 74, alignment: .leading)
            Text(v).foregroundStyle(Term.text)
        }
        .font(Term.mono(12.5))
    }
}
