import Foundation
import SafariServices

/// Safari 웹 확장 "NAGO"의 네이티브 쪽: 팝업이 browser.runtime.sendNativeMessage로 물으면
/// 같은 앱의 콘텐츠 차단기(NAGO Blocker)가 켜졌는지·규칙 몇 개인지 알려 준다.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem
        let message = request?.userInfo?[SFExtensionMessageKey] as? [String: Any]
        let type = message?["type"] as? String ?? "status"
        guard type == "status" else {
            reply(context, ["error": "unknown message"])
            return
        }
        var answer: [String: Any] = ["found": false]
        if let info = BlockerLocator.info {
            answer["rules"] = info.rules
            answer["lists"] = info.lists
            answer["built"] = info.built
        }
        guard let id = BlockerLocator.identifier else {
            reply(context, answer)
            return
        }
        answer["found"] = true
        SFContentBlockerManager.getStateOfContentBlocker(withIdentifier: id) { state, error in
            answer["enabled"] = state?.isEnabled ?? false
            if let error { answer["error"] = (error as NSError).localizedDescription }
            self.reply(context, answer)
        }
    }

    private func reply(_ context: NSExtensionContext, _ answer: [String: Any]) {
        let item = NSExtensionItem()
        item.userInfo = [SFExtensionMessageKey: answer]
        context.completeRequest(returningItems: [item], completionHandler: nil)
    }
}
