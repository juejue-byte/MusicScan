import PhotosUI
import SwiftUI
import UIKit
import VisionKit
import WebKit

/// The MusicScan web editor (web/) in a WKWebView, plus the native pieces it asks for through
/// `window.webkit.messageHandlers.musicscan` (see web/js/native.js):
///   scan      Apple's document camera (edge detection + perspective fix), photo picker on the simulator
///   share     export through the share sheet (Files, AirDrop, Mail, ...)
///   haptic    taps while dragging notes
///   settings  the server address sheet
struct EditorWebView: UIViewRepresentable {
    let url: URL
    let reloadToken: Int
    var onLoaded: () -> Void
    var onLoadError: (String) -> Void
    var onOpenSettings: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(WeakMessageHandler(context.coordinator), name: "musicscan")
        // Tell the page which build it runs in before any of its scripts start.
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        config.userContentController.addUserScript(WKUserScript(
            source: "window.MUSICSCAN_APP = { platform: 'ios', version: '\(version)' };",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never  // the page pads itself with env(safe-area-inset-*)
        webView.scrollView.bounces = false
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.965, green: 0.969, blue: 0.976, alpha: 1)  // --bg in style.css
        webView.underPageBackgroundColor = webView.backgroundColor
        if #available(iOS 16.4, *) { webView.isInspectable = true }  // Safari > Develop > [device] > MusicScan

        context.coordinator.webView = webView
        context.coordinator.load(url, token: reloadToken)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.load(url, token: reloadToken)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler,
        VNDocumentCameraViewControllerDelegate, PHPickerViewControllerDelegate {
        var parent: EditorWebView
        weak var webView: WKWebView?
        private var loadedURL: URL?
        private var loadedToken = -1
        private var scanRequest = 0
        private let selection = UISelectionFeedbackGenerator()

        init(_ parent: EditorWebView) { self.parent = parent }

        func load(_ url: URL, token: Int) {
            guard let webView, url != loadedURL || token != loadedToken else { return }
            loadedURL = url
            loadedToken = token
            webView.load(URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 8))
        }

        // MARK: navigation

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { parent.onLoaded() }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code == NSURLErrorCancelled { return }  // superseded by a newer load
            parent.onLoadError(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code == NSURLErrorCancelled { return }
            parent.onLoadError(error.localizedDescription)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.reload()  // the score is kept in localStorage; the page offers "Continue editing"
        }

        // Links off the MusicScan server (licenses, credits) open in Safari.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let target = action.request.url, action.navigationType == .linkActivated,
               target.host != loadedURL?.host || target.port != loadedURL?.port {
                UIApplication.shared.open(target)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let target = action.request.url { UIApplication.shared.open(target) }
            return nil
        }

        // MARK: bridge

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
            let id = (body["id"] as? NSNumber)?.intValue ?? 0
            switch cmd {
            case "haptic": haptic(body["kind"] as? String ?? "selection")
            case "scan": scan(id)
            case "share": share(id, name: body["name"] as? String ?? "score", b64: body["b64"] as? String ?? "")
            case "settings": parent.onOpenSettings()
            default: reply(id, ["error": "Unknown command: \(cmd)"])
            }
        }

        private func reply(_ id: Int, _ result: [String: Any]) {
            guard id != 0 else { return }
            webView?.callAsyncJavaScript("window.__msNativeReply(id, result)",
                                         arguments: ["id": id, "result": result], in: nil, in: .page) { _ in }
        }

        private func presenter() -> UIViewController? {
            var vc = webView?.window?.rootViewController
            while let next = vc?.presentedViewController { vc = next }
            return vc
        }

        private func haptic(_ kind: String) {
            switch kind {
            case "light": UIImpactFeedbackGenerator(style: .light).impactOccurred()
            case "medium": UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            case "success": UINotificationFeedbackGenerator().notificationOccurred(.success)
            case "warning": UINotificationFeedbackGenerator().notificationOccurred(.warning)
            default:
                selection.selectionChanged()
                selection.prepare()
            }
        }

        // MARK: capture

        private func scan(_ id: Int) {
            scanRequest = id
            if VNDocumentCameraViewController.isSupported {
                let camera = VNDocumentCameraViewController()
                camera.delegate = self
                presenter()?.present(camera, animated: true)
            } else {
                // Simulator and devices without a camera: pick a photo instead.
                var config = PHPickerConfiguration()
                config.filter = .images
                config.selectionLimit = 1
                let picker = PHPickerViewController(configuration: config)
                picker.delegate = self
                presenter()?.present(picker, animated: true)
            }
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let pages = scan.pageCount
            let image = pages > 0 ? scan.imageOfPage(at: 0) : nil
            controller.dismiss(animated: true)
            deliver(image, pages: pages)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            controller.dismiss(animated: true)
            reply(scanRequest, [:])
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            controller.dismiss(animated: true)
            reply(scanRequest, ["error": error.localizedDescription])
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else {
                reply(scanRequest, [:])
                return
            }
            provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
                DispatchQueue.main.async { self?.deliver(object as? UIImage, pages: 1) }
            }
        }

        private func deliver(_ image: UIImage?, pages: Int) {
            let id = scanRequest
            guard let image else { reply(id, [:]); return }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let jpeg = image.limited(toLongSide: 4000).jpegData(compressionQuality: 0.9) else {
                    DispatchQueue.main.async { self?.reply(id, ["error": "Could not read the scanned image."]) }
                    return
                }
                let stamp = ISO8601DateFormatter().string(from: Date()).prefix(19).replacingOccurrences(of: ":", with: "-")
                let result: [String: Any] = ["b64": jpeg.base64EncodedString(), "name": "Scan \(stamp).jpg", "pages": pages]
                DispatchQueue.main.async { self?.reply(id, result) }
            }
        }

        // MARK: export

        private func share(_ id: Int, name: String, b64: String) {
            guard let data = Data(base64Encoded: b64), let webView else {
                reply(id, ["error": "Nothing to share."])
                return
            }
            let safe = (name as NSString).lastPathComponent.replacingOccurrences(of: "/", with: "-")
            let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(safe.isEmpty ? "score" : safe)
            do { try data.write(to: fileURL, options: .atomic) } catch {
                reply(id, ["error": error.localizedDescription])
                return
            }
            let sheet = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
            sheet.completionWithItemsHandler = { [weak self] _, completed, _, _ in self?.reply(id, ["completed": completed]) }
            if let pop = sheet.popoverPresentationController {  // iPad: anchor near the Export button
                pop.sourceView = webView
                pop.sourceRect = CGRect(x: webView.bounds.maxX - 80, y: webView.safeAreaInsets.top + 24, width: 1, height: 1)
            }
            presenter()?.present(sheet, animated: true)
        }
    }
}

/// WKUserContentController keeps its handlers alive; this keeps it from keeping the coordinator alive.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

private extension UIImage {
    /// The reader does not gain from more than ~4000 px; keeps uploads small on 48 MP cameras.
    func limited(toLongSide maxSide: CGFloat) -> UIImage {
        let longSide = max(size.width, size.height) * scale
        guard longSide > maxSide else { return self }
        let k = maxSide / longSide
        let target = CGSize(width: (size.width * scale * k).rounded(), height: (size.height * scale * k).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
    }
}
