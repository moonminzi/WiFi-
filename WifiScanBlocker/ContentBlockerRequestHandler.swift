import Foundation

/// Safari 콘텐츠 차단기: 배너 광고·광고 칸을 페이지 안에서 숨기고 광고 주소를 막는다(EasyList + List-KR).
/// 규칙(blockerList.json)은 CI가 목록을 받아 tools/safari-blocker/convert.py로 만들고 WebKit으로 컴파일해 본 것.
/// iOS 설정 → 앱 → Safari → 확장 프로그램에서 켠다. Safari(와 SFSafariViewController)에만 듣는다.
final class ContentBlockerRequestHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = NSExtensionItem()
        if let url = Bundle.main.url(forResource: "blockerList", withExtension: "json"),
           let attachment = NSItemProvider(contentsOf: url) {
            item.attachments = [attachment]
        }
        context.completeRequest(returningItems: [item], completionHandler: nil)
    }
}
