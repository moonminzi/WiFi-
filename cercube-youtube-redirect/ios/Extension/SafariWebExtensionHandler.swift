import SafariServices
import os.log

/// Safari 웹 확장의 네이티브 쪽. 리다이렉트는 전부 content.js가 하므로
/// 여기서는 확장이 보내는 메시지(쓰지 않음)에 응답만 돌려준다.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey]
        os_log(.default, "YTRedirect: native message %{public}@", String(describing: message))

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: ["ok": true]]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
