import SwiftUI
import UIKit

@main
struct YTRedirectApp: App {
    var body: some Scene {
        WindowGroup {
            SetupView()
                .preferredColorScheme(.dark)
        }
    }
}

/// 설치 안내 화면. 앱 자체는 하는 일이 없고, Safari 확장을 켜는 방법과 동작 확인만 보여준다.
struct SetupView: View {
    @State private var appCheck: (kind: StatusLine.Kind, text: String)?

    /// "Me at the zoo" — 유튜브 첫 영상. 지워질 일이 없어 시험용으로 쓴다.
    private let testLink = "https://youtu.be/jNQXAC9IVRw"

    var body: some View {
        TermPage(path: "yt-redirect") {
            TermWindow(title: "yt-redirect — safari extension") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Safari에서 유튜브 링크를 누르면")
                    Text("바로 유튜브(Cercube) 앱으로 넘겨줍니다.")
                    TermDivider().padding(.vertical, 4)
                    line("youtu.be/ID", "youtube://…/watch?v=ID")
                    line("/shorts/ID", "youtube://…/shorts/ID")
                    line("/@채널", "youtube://…/@채널")
                }
                .font(Term.mono(13))
            }

            TermBlock(label: "setup — 한 번만 하면 됩니다") {
                step(1, "설정 → 앱 → Safari → 확장 프로그램", note: "iOS 17 이하는 설정 → Safari → 확장 프로그램")
                step(2, "'YT 리다이렉트' 켜기")
                step(3, "권한: youtube.com · youtu.be → 허용", note: "'모든 웹사이트 → 허용'도 됩니다")
                step(4, "Safari에서 유튜브 링크 누르기 → 앱으로 열림")
                Button("설정 열기") { open(UIApplication.openSettingsURLString) }
                    .buttonStyle(.termPrimary)
                    .padding(.top, 4)
            }

            TermBlock(label: "test") {
                Button("유튜브 앱이 깔려 있는지 확인") { checkYouTubeApp() }
                    .buttonStyle(.term)
                if let appCheck {
                    StatusLine(kind: appCheck.kind, text: appCheck.text)
                }
                TermDivider()
                Button("Safari로 시험 링크 열기") { open(testLink) }
                    .buttonStyle(.term)
                Text("확장이 켜져 있으면 Safari가 잠깐 열렸다가 유튜브 앱으로 넘어갑니다.")
                    .font(Term.mono(12))
                    .foregroundStyle(Term.muted)
            }

            TermBlock(label: "note") {
                VStack(alignment: .leading, spacing: 8) {
                    bullet("Cercube처럼 재서명한 유튜브 앱은 유니버설 링크가 빠져서 Safari 링크가 앱으로 안 넘어갑니다. 이 확장이 그걸 대신합니다.")
                    bullet("처음엔 Safari가 'YouTube에서 열겠습니까?'라고 물을 수 있어요. '열기'를 누르세요.")
                    bullet("잠깐 끄려면 Safari 주소창의 확장(🧩) 메뉴 → YT 리다이렉트 → 토글.")
                    bullet("music.youtube.com · 임베드 영상은 넘기지 않습니다.")
                }
                .font(Term.mono(12))
                .foregroundStyle(Term.muted)
            }
        }
    }

    // MARK: - 조각

    private func line(_ from: String, _ to: String) -> some View {
        HStack(spacing: 6) {
            Text(from).foregroundStyle(Term.key)
            Text("→").foregroundStyle(Term.muted)
            Text(to).foregroundStyle(Term.green)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private func step(_ number: Int, _ text: String, note: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)").foregroundStyle(Term.green).font(Term.mono(14, .bold))
            VStack(alignment: .leading, spacing: 2) {
                Text(text).font(Term.mono(14))
                if let note {
                    Text(note).font(Term.mono(11.5)).foregroundStyle(Term.muted)
                }
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("-")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 동작

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        UIApplication.shared.open(url)
    }

    /// youtube:// 를 직접 열어 본다. 열리면 유튜브 앱으로 넘어가고, 앱이 없으면 실패가 돌아온다.
    private func checkYouTubeApp() {
        appCheck = (kind: .running, text: "youtube:// 여는 중…")
        guard let url = URL(string: "youtube://") else { return }
        UIApplication.shared.open(url) { opened in
            if opened {
                appCheck = (kind: .ok, text: "유튜브 앱이 열렸습니다 — 준비 완료")
            } else {
                appCheck = (kind: .error, text: "유튜브(Cercube) 앱을 찾지 못했습니다")
            }
        }
    }
}
