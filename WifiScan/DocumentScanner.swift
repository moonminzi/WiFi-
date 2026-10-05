import SwiftUI
import UIKit
import VisionKit

/// 시스템 문서 스캐너. 모서리를 자동으로 잡고 평평하게 펴 준다. 취소하면 nil.
struct DocumentScanner: UIViewControllerRepresentable {
    var onFinish: ([UIImage]?) -> Void

    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: ([UIImage]?) -> Void
        init(onFinish: @escaping ([UIImage]?) -> Void) { self.onFinish = onFinish }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan
        ) {
            onFinish((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onFinish(nil)
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            onFinish(nil)
        }
    }
}

enum PDFBuilder {
    /// 스캔한 페이지들을 PDF 하나로 묶는다. 페이지 폭은 A4(595pt)에 맞추고 이미지는 200dpi 정도로 줄여 용량을 아낀다.
    static func makePDF(from pages: [UIImage], to url: URL) throws {
        let width: CGFloat = 595.2
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: width, height: 841.8))
        try renderer.writePDF(to: url) { context in
            for page in pages {
                let size = page.size
                guard size.width > 0, size.height > 0 else { continue }
                let rect = CGRect(x: 0, y: 0, width: width, height: width * size.height / size.width)
                context.beginPage(withBounds: rect, pageInfo: [:])
                let image = downscaled(page, maxDimension: 2000)
                // JPEG로 한 번 거쳐서 넣으면 PDF 안에도 JPEG로 들어가 용량이 크게 줄어든다
                if let data = image.jpegData(compressionQuality: 0.7), let jpeg = UIImage(data: data) {
                    jpeg.draw(in: rect)
                } else {
                    image.draw(in: rect)
                }
            }
        }
    }

    private static func downscaled(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
