import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 파일 앱에서 파일 하나를 고르는 UIKit 피커.
///
/// SwiftUI `.fileImporter`는 고른 파일을 원래 위치 그대로 넘겨서(보안 범위 접근 필요) 재서명한 앱이나
/// 아직 안 받은 iCloud 파일에서는 골라도 아무 일도 안 일어나는 경우가 있다.
/// `asCopy: true`로 열면 시스템이 파일을 받아서 앱 임시 폴더에 복사한 뒤 넘겨준다.
struct DocumentPicker: UIViewControllerRepresentable {
    /// 고른 파일(복사본) 주소. 취소하면 nil.
    let onPick: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL?) -> Void

        init(onPick: @escaping (URL?) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPick(nil)
        }
    }
}
