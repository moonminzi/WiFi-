import UIKit
import UniformTypeIdentifiers

/// 파일 앱에서 고르기. SwiftUI fileImporter 대신 UIKit 문서 선택기를 맨 위 화면에서 직접 띄운다.
/// - 복사본으로 받는다(asCopy): iCloud·다른 저장소 파일도 선택기가 다 받아 앱 임시 폴더에 복사한 뒤 넘겨 주므로
///   보안 범위 접근이나 다운로드 대기 없이 바로 읽힌다. 복사본은 가져온 뒤 지운다
/// - ZIP·여러 개를 골라 "열기"를 눌러도 SwiftUI 쪽 표시 상태와 상관없이 바로 넘어온다
final class DocumentPicker: NSObject, UIDocumentPickerDelegate {
    static let shared = DocumentPicker()
    private var onPick: (([URL]) -> Void)?

    @MainActor
    func present(types: [UTType], multiple: Bool = true, onPick: @escaping ([URL]) -> Void) {
        guard let top = Self.topViewController() else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = multiple
        picker.shouldShowFileExtensions = true
        picker.delegate = self
        self.onPick = onPick
        top.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let done = onPick
        onPick = nil
        done?(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        onPick = nil
    }

    /// 지금 맨 위에 떠 있는 화면(띄울 곳)
    @MainActor
    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }
}
