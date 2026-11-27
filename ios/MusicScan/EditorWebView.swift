import AVFoundation
import Observation
import SuperwallKit
import SwiftUI
import WebKit

#if os(iOS)
import PhotosUI
import UIKit
import UniformTypeIdentifiers
#endif

/// Tracks which top-level screen the embedded MusicScan web app is currently showing
/// so native chrome and tabs stay in sync with the live score workspace.
enum WorkspaceStage: String, Sendable, Equatable {
    case home
    case reading
    case editor
}

/// Real sample sheet-music entry exposed by the live MusicScan server (`api/samples`).
struct WebSampleItem: Identifiable, Equatable, Sendable {
    let id: Int
    let title: String
    let thumbURL: String
}

/// Bridges native SwiftUI tabs and controls to the embedded `WKWebView` without tight view coupling.
@MainActor
@Observable
final class MusicScanBridgeController {
    var stage: WorkspaceStage = .home
    var documentTitle: String = ""
    var isEditing: Bool = false
    var isPlaying: Bool = false
    var libraryCount: Int = 0
    var libraryReady: Bool = false
    var hasResume: Bool = false
    var isModalOpen: Bool = false
    var fastMode: Bool = false
    var samples: [WebSampleItem] = []
    var toastMessage: String?
    /// Non-nil immediately after picking photos/files while images are downscaled & handed to the reader,
    /// eliminating the silent dead-zone between picker dismissal and upload start.
    var preparingMessage: String?
    var preparingProgress: Double?

    #if os(iOS)
    fileprivate weak var coordinator: EditorWebView.Coordinator?
    #endif

    /// Opens our manual Vision-powered multi-page document camera on device (or photo library on simulator).
    func triggerScan() {
        #if os(iOS)
        coordinator?.triggerNativeScan(forcePhotoLibrary: false)
        #endif
    }

    /// Opens the native iOS photo library picker for selecting one or more sheet-music photos.
    func triggerPhotoPicker() {
        #if os(iOS)
        coordinator?.triggerNativeScan(forcePhotoLibrary: true)
        #endif
    }

    /// Opens the native iOS Files document picker for PDF, JPG/PNG/HEIC, or MusicXML/MXL files.
    func triggerImport() {
        #if os(iOS)
        coordinator?.presentNativeDocumentPicker()
        #endif
    }

    func setFastMode(_ enabled: Bool) {
        fastMode = enabled
        #if os(iOS)
        coordinator?.setFastModeInWeb(enabled)
        #endif
    }

    func openSample(index: Int) {
        #if os(iOS)
        coordinator?.openSampleInWeb(index: index)
        #endif
    }

    func openResume() {
        #if os(iOS)
        coordinator?.openResumeInWeb()
        #endif
    }

    func showLibraryHome() {
        #if os(iOS)
        coordinator?.showLibraryHomeInWeb()
        #endif
    }

    func setReviewTabMode(_ enabled: Bool) {
        #if os(iOS)
        coordinator?.setReviewTabModeInWeb(enabled)
        #endif
    }

    func sendCommand(_ command: String) {
        #if os(iOS)
        coordinator?.sendEditorCommand(command)
        #endif
    }

    func syncProState() {
        #if os(iOS)
        coordinator?.syncProStateToWeb()
        #endif
    }
}

/// Native iOS/iPadOS shell around the MusicScan web editor (`web/`).
///
/// Implements the `window.webkit.messageHandlers.musicscan` bridge (`web/js/native.js`):
/// - `scan`      VisionKit multi-page document camera on device (PHPicker photo library on simulator)
/// - `share`     Native share sheet for MuseScore (`.musicxml`) and `.mid` export (popover-anchored on iPad)
/// - `haptic`    Tactile feedback while dragging notes or adding symbols
/// - `settings`  Opens the native Account & Settings sheet
/// - `guide`     Opens the native Quick Guide & Shortcuts sheet
/// - `paywall`   Opens the native Superwall / StoreKit 2 paywall, verifies with the server, and unlocks the active job
/// - `restore`   Restores Apple subscriptions and syncs with the server
/// - `state`     Reports active screen (`home`/`reading`/`editor`) so native chrome stays unobtrusive
///
/// Also supports iPad hardware-keyboard `⌘` shortcuts and Apple Pencil double-tap via `window.__msCommand`.
#if os(iOS)
struct EditorWebView: UIViewRepresentable {
    let url: URL
    let reloadToken: Int
    let isPro: Bool
    let controller: MusicScanBridgeController
    var onLoaded: () -> Void
    var onLoadError: (String) -> Void
    var onOpenSettings: () -> Void
    var onOpenGuide: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.add(WeakScriptMessageHandler(context.coordinator), name: "musicscan")

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        config.userContentController.addUserScript(WKUserScript(
            source: "window.MUSICSCAN_APP = { platform: 'ios', version: '\(version)', nativePaywall: true };",
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        config.userContentController.addUserScript(WKUserScript(
            source: MusicScanNativeBridgeScript.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        config.userContentController.addUserScript(WKUserScript(
            source: NativeWebPolishScript.source,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))

        let webView = EditorWKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.bounces = false
        webView.scrollView.alwaysBounceHorizontal = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 0.961, green: 0.980, blue: 1.0, alpha: 1)
        webView.underPageBackgroundColor = webView.backgroundColor
        webView.isInspectable = true

        // Apple Pencil (2nd gen / Pro) double-tap toggles Select / Add notes (or Pen / Eraser in Ink mode).
        let pencil = UIPencilInteraction()
        pencil.delegate = context.coordinator
        webView.addInteraction(pencil)

        context.coordinator.webView = webView
        controller.coordinator = context.coordinator
        context.coordinator.load(url, token: reloadToken)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        controller.coordinator = context.coordinator
        context.coordinator.load(url, token: reloadToken)
        context.coordinator.syncProStateIfNeeded(isPro)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler,
        PHPickerViewControllerDelegate, UIDocumentPickerDelegate,
        UIPencilInteractionDelegate {
        var parent: EditorWebView
        weak var webView: WKWebView?

        private var loadedURL: URL?
        private var loadedToken = -1
        private var isWebReady = false
        private var pendingWebDelivery: (() -> Void)?
        private var lastSyncedPro: Bool?
        private var lastWarmupAt: Date?
        private var scanRequestID = 0
        private var preferPhotoLibraryForNextScan = false
        private let selectionFeedback = UISelectionFeedbackGenerator()

        init(_ parent: EditorWebView) {
            self.parent = parent
        }

        private func ensurePlaybackAudioSessionActive() {
            let audio = AVAudioSession.sharedInstance()
            try? audio.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? audio.setActive(true)
        }

        func load(_ url: URL, token: Int) {
            guard let webView, url != loadedURL || token != loadedToken else { return }
            loadedURL = url
            loadedToken = token
            isWebReady = false
            parent.controller.libraryReady = false
            BillingManager.shared.updateServerURL(url)
            let cookieStore = webView.configuration.websiteDataStore.httpCookieStore

            Task { @MainActor in
                // Skip redundant /api/config round-trip on default server when Supabase is already configured,
                // avoiding extra startup latency and unnecessary Modal wake-up traffic.
                let defaultHost = URL(string: AppConfig.fallbackServerURL)?.host?.lowercased()
                if !AuthManager.shared.isConfigured || url.host?.lowercased() != defaultHost {
                    await AuthManager.shared.bootstrapConfig(from: url)
                }
                await AuthManager.shared.prepareWebView(cookieStore, for: url)
                let request = URLRequest(
                    url: url,
                    cachePolicy: .useProtocolCachePolicy,
                    timeoutInterval: 90
                )
                webView.load(request)
            }
        }

        func sendEditorCommand(_ command: String) {
            (webView as? EditorWKWebView)?.sendCommand(command)
        }

        /// Presents the live Vision manual document scanner or photo library immediately in Swift (0 ms JS round-trip).
        func triggerNativeScan(forcePhotoLibrary: Bool) {
            triggerHaptic("light")
            preferPhotoLibraryForNextScan = forcePhotoLibrary
            startScan(requestID: 0)
        }

        func presentNativeDocumentPicker() {
            triggerHaptic("light")
            var types: [UTType] = [.pdf, .image, .xml]
            if let musicXML = UTType(filenameExtension: "musicxml") {
                types.append(musicXML)
            }
            if let mxl = UTType(filenameExtension: "mxl") {
                types.append(mxl)
            }
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
            picker.allowsMultipleSelection = false
            picker.delegate = self
            presenterViewController()?.present(picker, animated: true)
        }

        private func deliverWhenWebReady(_ action: @escaping @MainActor () -> Void) {
            if isWebReady {
                action()
            } else {
                pendingWebDelivery = action
            }
        }

        func setFastModeInWeb(_ enabled: Bool) {
            webView?.callAsyncJavaScript(
                """
                const el = document.getElementById('optFast');
                if (el) { el.checked = Boolean(enabled); }
                """,
                arguments: ["enabled": enabled],
                in: nil,
                in: .page
            ) { _ in }
        }

        func openSampleInWeb(index: Int) {
            triggerHaptic("light")
            webView?.callAsyncJavaScript(
                """
                const samples = document.querySelectorAll('#samples .sample');
                const target = samples[index];
                if (target) target.click();
                """,
                arguments: ["index": index],
                in: nil,
                in: .page
            ) { _ in }
        }

        func openResumeInWeb() {
            triggerHaptic("light")
            webView?.evaluateJavaScript("""
                (() => {
                  const resume = document.getElementById('resume');
                  if (resume) { resume.click(); return; }
                  const first = document.querySelector('#library .lib-open');
                  if (first) first.click();
                })();
            """)
        }

        func showLibraryHomeInWeb() {
            triggerHaptic("selection")
            webView?.evaluateJavaScript("""
                (() => {
                  const btn = document.getElementById('btnNew');
                  if (btn && document.body.classList.contains('editing')) {
                    btn.click();
                  }
                })();
            """)
        }

        func setReviewTabModeInWeb(_ enabled: Bool) {
            webView?.callAsyncJavaScript(
                "window.__msSetReviewTabMode && window.__msSetReviewTabMode(enabled)",
                arguments: ["enabled": enabled],
                in: nil,
                in: .page
            ) { _ in }
        }

        func syncProStateIfNeeded(_ isPro: Bool) {
            guard lastSyncedPro != isPro else { return }
            syncProStateToWeb(isPro)
        }

        func syncProStateToWeb(_ explicitPro: Bool? = nil) {
            let isPro = explicitPro ?? BillingManager.shared.isPro
            lastSyncedPro = isPro
            webView?.callAsyncJavaScript(
                "window.__msSetNativePro && window.__msSetNativePro(isPro)",
                arguments: ["isPro": isPro],
                in: nil,
                in: .page
            ) { _ in }
        }

        // MARK: - WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isWebReady = true
            parent.onLoaded()
            webView.becomeFirstResponder()
            syncProStateToWeb()
            setReviewTabModeInWeb(true)
            setFastModeInWeb(parent.controller.fastMode)
            if let pending = pendingWebDelivery {
                pendingWebDelivery = nil
                pending()
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code == NSURLErrorCancelled { return }
            parent.onLoadError(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code == NSURLErrorCancelled { return }
            parent.onLoadError(error.localizedDescription)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.reload()
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            if let target = action.request.url,
               action.navigationType == .linkActivated,
               target.host != loadedURL?.host || target.port != loadedURL?.port {
                UIApplication.shared.open(target)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for action: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let target = action.request.url {
                UIApplication.shared.open(target)
            }
            return nil
        }

        // MARK: - Apple Pencil

        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            guard UIPencilInteraction.preferredTapAction != .ignore else { return }
            (webView as? EditorWKWebView)?.sendCommand("toggle-mode")
        }

        // MARK: - JS Bridge

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let cmd = body["cmd"] as? String else {
                return
            }
            let id = (body["id"] as? NSNumber)?.intValue ?? 0

            switch cmd {
            case "haptic":
                triggerHaptic(body["kind"] as? String ?? "selection")
            case "scan":
                startScan(requestID: id)
            case "share":
                presentShareSheet(
                    requestID: id,
                    name: body["name"] as? String ?? "score.musicxml",
                    base64: body["b64"] as? String ?? ""
                )
            case "settings", "account":
                parent.onOpenSettings()
            case "guide":
                parent.onOpenGuide()
            case "state":
                if let rawStage = body["stage"] as? String,
                   let parsedStage = WorkspaceStage(rawValue: rawStage) {
                    if parent.controller.stage == .reading && parsedStage == .editor {
                        triggerHaptic("success")
                    }
                    if parsedStage == .editor && parent.controller.stage != .editor {
                        ensurePlaybackAudioSessionActive()
                    }
                    parent.controller.stage = parsedStage
                    if parsedStage == .reading || parsedStage == .editor {
                        parent.controller.preparingMessage = nil
                        parent.controller.preparingProgress = nil
                    }
                }
                parent.controller.documentTitle = body["title"] as? String ?? ""
                parent.controller.isEditing = body["editing"] as? Bool ?? false
                let nowPlaying = body["playing"] as? Bool ?? false
                if nowPlaying && !parent.controller.isPlaying {
                    ensurePlaybackAudioSessionActive()
                }
                parent.controller.isPlaying = nowPlaying
                if let libCount = (body["libraryCount"] as? NSNumber)?.intValue {
                    parent.controller.libraryCount = libCount
                }
                if let libReady = body["libraryReady"] as? Bool {
                    parent.controller.libraryReady = libReady
                }
                if let hasResume = body["hasResume"] as? Bool {
                    parent.controller.hasResume = hasResume
                }
                if let modalOpen = body["modalOpen"] as? Bool {
                    parent.controller.isModalOpen = modalOpen
                }
                if let fastMode = body["fastMode"] as? Bool {
                    parent.controller.fastMode = fastMode
                }
                if let rawSamples = body["samples"] as? [[String: Any]] {
                    let parsed = rawSamples.compactMap { item -> WebSampleItem? in
                        guard let idx = (item["index"] as? NSNumber)?.intValue,
                              let title = item["title"] as? String else { return nil }
                        let thumb = item["thumb"] as? String ?? ""
                        return WebSampleItem(id: idx, title: title, thumbURL: thumb)
                    }
                    if parsed != parent.controller.samples {
                        parent.controller.samples = parsed
                    }
                }
                if let toast = body["toast"] as? String {
                    parent.controller.toastMessage = toast.isEmpty ? nil : toast
                }
            case "paywall":
                let reason = body["reason"] as? String
                    ?? "The whole page is ready. Subscribe to unlock every bar, edit, play back, mark up, and export to MuseScore."
                let jobID = body["jobId"] as? String
                handlePaywallRequest(requestID: id, reason: reason, jobID: jobID)
            case "restore":
                handleRestoreRequest(requestID: id)
            case "scanSLI":
                let jobID = body["jobId"] as? String ?? ""
                let title = (body["title"] as? String ?? parent.controller.documentTitle)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let pageNumber = (body["pageNumber"] as? NSNumber)?.intValue ?? 1
                let totalPages = (body["totalPages"] as? NSNumber)?.intValue ?? 1
                let wallSeconds = (body["wallSeconds"] as? NSNumber)?.doubleValue ?? 0
                let omrSeconds = (body["omrSeconds"] as? NSNumber)?.doubleValue
                let measuresCount = (body["measures"] as? NSNumber)?.intValue ?? 0
                let fastMode = body["fastMode"] as? Bool ?? parent.controller.fastMode
                let accessMode = body["access"] as? String ?? "full"
                ScanSLIRecorder.shared.recordPageCompletion(
                    title: title,
                    jobID: jobID,
                    pageNumber: pageNumber,
                    totalPages: totalPages,
                    pageWallSeconds: wallSeconds,
                    serverOmrSeconds: omrSeconds,
                    measuresCount: measuresCount,
                    fastMode: fastMode,
                    accessMode: accessMode
                )
            default:
                reply(id, ["error": "Unknown command: \(cmd)"])
            }
        }

        private func handlePaywallRequest(requestID: Int, reason: String, jobID: String?) {
            Task { @MainActor in
                let unlocked = await BillingManager.shared.presentPaywall(
                    placement: AppConfig.superwallUnlockPlacement,
                    reason: reason,
                    jobID: jobID
                )
                guard unlocked else {
                    reply(requestID, ["unlocked": false])
                    return
                }
                syncProStateToWeb()
                if let jobID, !jobID.isEmpty {
                    do {
                        let fullJob = try await BillingManager.shared.unlockJob(jobID: jobID)
                        applyUnlockedJobToWeb(jobID: jobID, jobPayload: fullJob)
                        reply(requestID, ["unlocked": true, "jobId": jobID])
                    } catch {
                        reply(requestID, ["unlocked": true, "error": error.localizedDescription])
                    }
                } else {
                    reply(requestID, ["unlocked": true])
                }
            }
        }

        private func handleRestoreRequest(requestID: Int) {
            Task { @MainActor in
                let result = await BillingManager.shared.restorePurchases()
                syncProStateToWeb()
                switch result {
                case .restored:
                    reply(requestID, ["restored": true, "isPro": BillingManager.shared.isPro])
                case .failed(let error):
                    reply(requestID, ["error": error?.localizedDescription ?? "Could not restore purchases."])
                }
            }
        }

        private func applyUnlockedJobToWeb(jobID: String, jobPayload: [String: Any]) {
            webView?.callAsyncJavaScript(
                "window.__msApplyUnlockedJob && window.__msApplyUnlockedJob(jobId, payload)",
                arguments: ["jobId": jobID, "payload": jobPayload],
                in: nil,
                in: .page
            ) { _ in }
        }

        private func reply(_ id: Int, _ result: [String: Any]) {
            guard id != 0 else { return }
            webView?.callAsyncJavaScript(
                "window.__msNativeReply && window.__msNativeReply(id, result)",
                arguments: ["id": id, "result": result],
                in: nil,
                in: .page
            ) { _ in }
        }

        private func presenterViewController() -> UIViewController? {
            var controller = webView?.window?.rootViewController
            while let presented = controller?.presentedViewController {
                controller = presented
            }
            return controller
        }

        private func triggerHaptic(_ kind: String) {
            switch kind {
            case "light":
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            case "medium":
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            case "success":
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            case "warning":
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            default:
                selectionFeedback.selectionChanged()
                selectionFeedback.prepare()
            }
        }

        // MARK: - Live Vision Manual Document Scanner & Photo Picker

        private var cameraAvailable: Bool {
            #if targetEnvironment(simulator)
            return false
            #else
            return AVCaptureDevice.default(for: .video) != nil
            #endif
        }

        /// Fires a debounced non-blocking ping to wake the Modal GPU worker only once pages are chosen,
        /// avoiding wasted GPU container wakeups when pickers are cancelled or local MusicXML is opened.
        private func warmupServerGPU() {
            guard isWebReady else { return }
            let now = Date()
            if let last = lastWarmupAt, now.timeIntervalSince(last) < 120 {
                return
            }
            lastWarmupAt = now
            webView?.evaluateJavaScript(
                "fetch('api/warmup', { method: 'POST', keepalive: true }).catch(() => {});",
                completionHandler: nil
            )
        }

        private func startScan(requestID: Int) {
            scanRequestID = requestID
            let usePhotos = preferPhotoLibraryForNextScan || !cameraAvailable
            preferPhotoLibraryForNextScan = false

            if !usePhotos {
                let scanner = ManualDocumentScannerViewController()
                scanner.modalPresentationStyle = .fullScreen
                scanner.onFinish = { [weak self] images in
                    guard let self else { return }
                    self.ensurePlaybackAudioSessionActive()
                    self.warmupServerGPU()
                    let pageCount = images.count
                    self.parent.controller.preparingMessage = pageCount > 1
                        ? "Preparing \(pageCount) pages…"
                        : "Preparing page…"
                    self.parent.controller.preparingProgress = 0.20
                    self.deliverScannedImages(images)
                }
                scanner.onCancel = { [weak self] in
                    guard let self else { return }
                    self.ensurePlaybackAudioSessionActive()
                    if self.scanRequestID != 0 {
                        let id = self.scanRequestID
                        self.scanRequestID = 0
                        self.reply(id, [:])
                    }
                }
                scanner.onChoosePhotosFallback = { [weak self] in
                    guard let self else { return }
                    self.ensurePlaybackAudioSessionActive()
                    let id = self.scanRequestID
                    self.preferPhotoLibraryForNextScan = true
                    self.startScan(requestID: id)
                }
                presenterViewController()?.present(scanner, animated: true)
            } else {
                var pickerConfig = PHPickerConfiguration()
                pickerConfig.filter = .images
                pickerConfig.selectionLimit = 0 // Allow multi-page image selection
                pickerConfig.selection = .ordered // Show 1, 2, 3, 4 badges and preserve exact tap order
                let picker = PHPickerViewController(configuration: pickerConfig)
                picker.delegate = self
                presenterViewController()?.present(picker, animated: true)
            }
        }

        // MARK: - Native Document Import (PDF, Photos, MusicXML)

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            let rawFileName = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            let isScoreMarkup = (ext == "musicxml" || ext == "xml" || ext == "mxl")
            let isRasterImage = ["jpg", "jpeg", "png", "heic", "heif", "webp", "tif", "tiff", "bmp"].contains(ext)

            if !isScoreMarkup {
                warmupServerGPU()
            }

            let fallbackMimeType: String
            switch ext {
            case "pdf":
                fallbackMimeType = "application/pdf"
            case "musicxml", "xml":
                fallbackMimeType = "application/xml"
            case "mxl":
                fallbackMimeType = "application/vnd.recordare.musicxml"
            case "png":
                fallbackMimeType = "image/png"
            case "heic", "heif":
                fallbackMimeType = "image/heic"
            case "webp":
                fallbackMimeType = "image/webp"
            default:
                fallbackMimeType = "image/jpeg"
            }

            parent.controller.preparingMessage = "Preparing \(rawFileName)…"
            parent.controller.preparingProgress = 0.25

            Task { @MainActor [weak self] in
                let prepared = await Task.detached(priority: .userInitiated) { () -> (String, String, String)? in
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer {
                        if accessing {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                    guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
                    if isRasterImage, let image = UIImage(data: data) {
                        let upright = SheetMusicOrientationNormalizer.normalize(image, maxLongSide: 2200)
                        if let jpeg = upright.jpegData(compressionQuality: 0.80) {
                            let baseName = (rawFileName as NSString).deletingPathExtension
                            return ("\(baseName).jpg", "image/jpeg", jpeg.base64EncodedString())
                        }
                    }
                    return (rawFileName, fallbackMimeType, data.base64EncodedString())
                }.value

                guard let self else { return }
                guard let (fileName, mimeType, base64) = prepared else {
                    self.parent.controller.preparingMessage = nil
                    self.parent.controller.preparingProgress = nil
                    self.parent.controller.toastMessage = "Could not read \(rawFileName)."
                    return
                }
                self.parent.controller.preparingMessage = self.isWebReady
                    ? "Opening \(fileName)…"
                    : "Connecting…"
                self.parent.controller.preparingProgress = 0.85

                self.deliverWhenWebReady { [weak self] in
                    guard let self else { return }
                    self.parent.controller.preparingProgress = 1.0
                    self.webView?.callAsyncJavaScript(
                        "window.__msImportFile && window.__msImportFile(name, mime, b64)",
                        arguments: [
                            "name": fileName,
                            "mime": mimeType,
                            "b64": base64
                        ],
                        in: nil,
                        in: .page
                    ) { [weak self] _ in
                        Task { @MainActor in
                            // Clear safety net if MusicXML opened synchronously or errored silently
                            try? await Task.sleep(for: .milliseconds(900))
                            if self?.parent.controller.stage == .home {
                                self?.parent.controller.preparingMessage = nil
                                self?.parent.controller.preparingProgress = nil
                            }
                        }
                    }
                }
            }
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard !results.isEmpty else {
                if scanRequestID != 0 {
                    reply(scanRequestID, [:])
                }
                return
            }

            let count = results.count
            warmupServerGPU()
            parent.controller.preparingMessage = count > 1
                ? "Loading \(count) photos…"
                : "Loading photo…"
            parent.controller.preparingProgress = 0.14

            let providers = results.map(\.itemProvider)
            Task { @MainActor in
                var images: [UIImage] = []
                for (index, provider) in providers.enumerated() where provider.canLoadObject(ofClass: UIImage.self) {
                    if let image = await Self.loadImage(from: provider) {
                        images.append(image)
                    }
                    let frac = 0.14 + 0.42 * (Double(index + 1) / Double(max(providers.count, 1)))
                    parent.controller.preparingProgress = frac
                }
                deliverScannedImages(images)
            }
        }

        private static func loadImage(from provider: NSItemProvider) async -> UIImage? {
            await withCheckedContinuation { continuation in
                provider.loadObject(ofClass: UIImage.self) { object, _ in
                    continuation.resume(returning: object as? UIImage)
                }
            }
        }

        private struct EncodedScanPayload: Sendable {
            let firstBase64: String
            let fileName: String
            let pageCount: Int
            let moreBase64: [String]
            let prepDurationMs: Int
        }

        private func deliverScannedImages(_ images: [UIImage]) {
            let id = scanRequestID
            scanRequestID = 0
            guard !images.isEmpty else {
                parent.controller.preparingMessage = nil
                parent.controller.preparingProgress = nil
                if id != 0 {
                    reply(id, [:])
                }
                return
            }

            parent.controller.preparingMessage = images.count > 1
                ? "Preparing \(images.count) pages…"
                : "Preparing page…"
            parent.controller.preparingProgress = 0.62

            Task { @MainActor [weak self] in
                let encoded = await Task.detached(priority: .userInitiated) { () -> EncodedScanPayload? in
                    let prepStart = CFAbsoluteTimeGetCurrent()
                    // Normalize sideways/upside-down photos on-device before upload, and cap at 2200 px long edge
                    // (0.80 JPEG quality) to match copisteria's 2048 px detector grid while saving Modal GPU & bandwidth.
                    let jpegs: [Data] = images.compactMap { image in
                        autoreleasepool {
                            SheetMusicOrientationNormalizer
                                .normalize(image, maxLongSide: 2200)
                                .jpegData(compressionQuality: 0.80)
                        }
                    }
                    guard let first = jpegs.first else { return nil }
                    let prepMs = Int(round((CFAbsoluteTimeGetCurrent() - prepStart) * 1000))
                    let stamp = ISO8601DateFormatter()
                        .string(from: Date())
                        .prefix(19)
                        .replacingOccurrences(of: ":", with: "-")
                    return EncodedScanPayload(
                        firstBase64: first.base64EncodedString(),
                        fileName: "Scan \(stamp).jpg",
                        pageCount: jpegs.count,
                        moreBase64: jpegs.dropFirst().map { $0.base64EncodedString() },
                        prepDurationMs: prepMs
                    )
                }.value

                guard let self else { return }
                guard let encoded else {
                    self.parent.controller.preparingMessage = nil
                    self.parent.controller.preparingProgress = nil
                    if id != 0 {
                        self.reply(id, ["error": "Could not read the scanned image."])
                    } else {
                        self.parent.controller.toastMessage = "Could not read the scanned image."
                    }
                    return
                }

                ScanSLIRecorder.shared.recordOnDevicePrep(
                    durationMs: encoded.prepDurationMs,
                    pageCount: encoded.pageCount
                )

                self.parent.controller.preparingMessage = self.isWebReady
                    ? "Uploading…"
                    : "Connecting…"
                self.parent.controller.preparingProgress = 0.88

                if id != 0 {
                    self.reply(id, [
                        "b64": encoded.firstBase64,
                        "name": encoded.fileName,
                        "pages": encoded.pageCount,
                        "more": encoded.moreBase64
                    ])
                } else {
                    self.deliverWhenWebReady { [weak self] in
                        guard let self else { return }
                        self.parent.controller.preparingProgress = 1.0
                        self.webView?.callAsyncJavaScript(
                            "window.__msImportScannedImages && window.__msImportScannedImages(name, b64, more)",
                            arguments: [
                                "name": encoded.fileName,
                                "b64": encoded.firstBase64,
                                "more": encoded.moreBase64
                            ],
                            in: nil,
                            in: .page
                        ) { [weak self] _ in
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(1200))
                                if self?.parent.controller.stage == .home {
                                    self?.parent.controller.preparingMessage = nil
                                    self?.parent.controller.preparingProgress = nil
                                }
                            }
                        }
                    }
                }
            }
        }

        // MARK: - Share Sheet Export (MuseScore / MusicXML / MIDI)

        private func presentShareSheet(requestID: Int, name: String, base64: String) {
            guard let data = Data(base64Encoded: base64), let webView else {
                reply(requestID, ["error": "Nothing to share."])
                return
            }
            let safeName = (name as NSString).lastPathComponent.replacingOccurrences(of: "/", with: "-")
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(safeName.isEmpty ? "score.musicxml" : safeName)
            do {
                try data.write(to: fileURL, options: .atomic)
            } catch {
                reply(requestID, ["error": error.localizedDescription])
                return
            }

            let activity = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
            activity.completionWithItemsHandler = { [weak self] _, completed, _, _ in
                Task { @MainActor in
                    self?.reply(requestID, ["completed": completed])
                }
            }
            if let popover = activity.popoverPresentationController {
                popover.sourceView = webView
                popover.sourceRect = CGRect(
                    x: webView.bounds.maxX - 80,
                    y: webView.safeAreaInsets.top + 24,
                    width: 1,
                    height: 1
                )
            }
            presenterViewController()?.present(activity, animated: true)
        }
    }
}

/// Prevents `WKUserContentController` from retaining the coordinator strongly.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// Custom `WKWebView` subclass exposing iPad hardware-keyboard `⌘` shortcuts.
final class EditorWKWebView: WKWebView {
    private static let shortcuts: [(String, String, UIKeyModifierFlags, String)] = [
        ("Undo", "z", .command, "undo"),
        ("Redo", "z", [.command, .shift], "redo"),
        ("Play / Stop", "\r", .command, "play"),
        ("Select", "1", .command, "mode-select"),
        ("Add Notes", "2", .command, "mode-add"),
        ("Ink", "3", .command, "mode-ink"),
        ("Show Photo", "p", [.command, .shift], "photo"),
        ("Fix It: Check Flagged Bars", "f", [.command, .shift], "review"),
        ("Next Flagged Bar", "]", .command, "review-next"),
        ("Previous Flagged Bar", "[", .command, "review-prev"),
        ("Looks Right", "\r", [.command, .shift], "review-accept"),
        ("Zoom In", "=", .command, "zoom-in"),
        ("Zoom Out", "-", .command, "zoom-out"),
        ("Export MusicXML", "s", .command, "export-xml"),
        ("Export MIDI", "s", [.command, .shift], "export-mid"),
        ("Scan a Page", "o", .command, "scan"),
        ("New Scan", "n", .command, "new"),
    ]

    override var keyCommands: [UIKeyCommand]? {
        let custom = Self.shortcuts.map { title, input, modifiers, command -> UIKeyCommand in
            let keyCommand = UIKeyCommand(
                title: title,
                action: #selector(runShortcut(_:)),
                input: input,
                modifierFlags: modifiers,
                propertyList: command
            )
            keyCommand.wantsPriorityOverSystemBehavior = true
            return keyCommand
        }
        return custom + (super.keyCommands ?? [])
    }

    @objc private func runShortcut(_ sender: UIKeyCommand) {
        if let command = sender.propertyList as? String {
            sendCommand(command)
        }
    }

    func sendCommand(_ command: String) {
        callAsyncJavaScript(
            "window.__msCommand && window.__msCommand(cmd)",
            arguments: ["cmd": command],
            in: nil,
            in: .page
        ) { _ in }
    }
}
#else
struct EditorWebView: NSViewRepresentable {
    let url: URL
    let reloadToken: Int
    let isPro: Bool
    let controller: MusicScanBridgeController
    var onLoaded: () -> Void
    var onLoadError: (String) -> Void
    var onOpenSettings: () -> Void
    var onOpenGuide: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(
            source: MusicScanNativeBridgeScript.source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.load(in: webView, url: url, token: reloadToken)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.load(in: webView, url: url, token: reloadToken)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: EditorWebView
        private var lastURL: URL?
        private var lastToken = -1

        init(_ parent: EditorWebView) { self.parent = parent }

        func load(in webView: WKWebView, url: URL, token: Int) {
            guard url != lastURL || token != lastToken else { return }
            lastURL = url
            lastToken = token
            let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
            Task { @MainActor in
                await AuthManager.shared.bootstrapConfig(from: url)
                await AuthManager.shared.prepareWebView(cookieStore, for: url)
                webView.load(URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 90))
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onLoaded()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code == NSURLErrorCancelled { return }
            parent.onLoadError(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code == NSURLErrorCancelled { return }
            parent.onLoadError(error.localizedDescription)
        }
    }
}
#endif

// MARK: - Injected Native Server-Allowance & Superwall Paywall Sync Script

/// Bridges the server's real `allowance.access` (`free`, `preview`, `full`, `cap`) into the MusicScan web editor:
/// - When the server returns a half-page `preview` scan, renders a blurred lower-half overlay and routes any
///   unlock/edit/play/export tap straight to the native Superwall / StoreKit 2 paywall.
/// - When the purchase is verified on the server and `POST /api/jobs/{id}/unlock` succeeds, seamlessly reloads
///   the full score and full page image right into the open editor.
private enum MusicScanNativeBridgeScript {
    static let source = #"""
    (() => {
      if (window.__msNativeBridgeInstalled) return;
      window.__msNativeBridgeInstalled = true;

      const previewJobs = new Set();
      const jobTimings = new Map();
      const recordedSLIJobs = new Set();
      let lastPendingPostStartMs = 0;
      let completedPageCounter = 0;
      let latestSLISummary = '';
      let nativeIsPro = false;
      let activePreviewJobId = null;
      let paywallPending = false;
      let seq = 900000;

      function postToNativeImmediate(cmd, args = {}) {
        try {
          window.webkit?.messageHandlers?.musicscan?.postMessage({ id: 0, cmd, ...args });
        } catch (_) {}
      }

      function callNative(cmd, args = {}) {
        const handler = window.webkit?.messageHandlers?.musicscan;
        if (!handler) return Promise.resolve({});
        const id = ++seq;
        return new Promise((resolve, reject) => {
          const prevReply = window.__msNativeReply;
          window.__msNativeBridgePending = window.__msNativeBridgePending || new Map();
          window.__msNativeBridgePending.set(id, { resolve, reject });
          if (!window.__msNativeReplyWrapped) {
            window.__msNativeReplyWrapped = true;
            window.__msNativeReply = (rid, result) => {
              const p = window.__msNativeBridgePending.get(rid);
              if (p) {
                window.__msNativeBridgePending.delete(rid);
                if (result && result.error) p.reject(new Error(result.error));
                else p.resolve(result);
                return;
              }
              if (typeof prevReply === 'function') prevReply(rid, result);
            };
          }
          handler.postMessage({ id, cmd, ...args });
        });
      }

      function injectStyles() {
        if (document.getElementById('msNativePreviewStyles')) return;
        const style = document.createElement('style');
        style.id = 'msNativePreviewStyles';
        style.textContent = `
          #scoreScroll {
            position: relative !important;
          }
          #msNativePreviewVeil {
            position: absolute;
            left: 0;
            right: 0;
            min-height: 250px;
            z-index: 38;
            display: flex;
            align-items: flex-end;
            justify-content: center;
            padding: 72px 18px 28px;
            box-sizing: border-box;
            overflow: hidden;
            pointer-events: auto;
          }
          #msNativePreviewVeil .ms-pv-blur-stack {
            position: absolute;
            inset: 0;
            pointer-events: none;
          }
          #msNativePreviewVeil .ms-pv-blur-1 {
            position: absolute;
            inset: 0;
            backdrop-filter: blur(2.5px);
            -webkit-backdrop-filter: blur(2.5px);
            mask-image: linear-gradient(180deg, rgba(0,0,0,0) 0%, rgba(0,0,0,0.85) 26%, #000 100%);
            -webkit-mask-image: linear-gradient(180deg, rgba(0,0,0,0) 0%, rgba(0,0,0,0.85) 26%, #000 100%);
          }
          #msNativePreviewVeil .ms-pv-blur-2 {
            position: absolute;
            inset: 14% 0 0 0;
            backdrop-filter: blur(7px);
            -webkit-backdrop-filter: blur(7px);
            mask-image: linear-gradient(180deg, rgba(0,0,0,0) 0%, rgba(0,0,0,0.9) 34%, #000 100%);
            -webkit-mask-image: linear-gradient(180deg, rgba(0,0,0,0) 0%, rgba(0,0,0,0.9) 34%, #000 100%);
          }
          #msNativePreviewVeil .ms-pv-blur-3 {
            position: absolute;
            inset: 30% 0 0 0;
            backdrop-filter: blur(15px) saturate(1.1);
            -webkit-backdrop-filter: blur(15px) saturate(1.1);
            mask-image: linear-gradient(180deg, rgba(0,0,0,0) 0%, rgba(0,0,0,0.95) 38%, #000 100%);
            -webkit-mask-image: linear-gradient(180deg, rgba(0,0,0,0) 0%, rgba(0,0,0,0.95) 38%, #000 100%);
          }
          #msNativePreviewVeil .ms-pv-tint {
            position: absolute;
            inset: 0;
            background: linear-gradient(
              180deg,
              rgba(255, 255, 255, 0.0) 0%,
              rgba(245, 250, 255, 0.36) 24%,
              rgba(234, 244, 254, 0.78) 56%,
              rgba(234, 244, 254, 0.94) 100%
            );
          }
          #msNativePreviewVeil .ms-pv-card {
            position: relative;
            z-index: 2;
            text-align: center;
            max-width: 430px;
            width: 100%;
            background: rgba(255, 255, 255, 0.90);
            backdrop-filter: blur(16px);
            -webkit-backdrop-filter: blur(16px);
            border: 1px solid rgba(23, 105, 194, 0.16);
            border-radius: 22px;
            padding: 20px 20px 18px;
            box-shadow: 0 14px 36px rgba(14, 34, 56, 0.14);
            color: #0E2238;
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif;
          }
          #msNativePreviewVeil .ms-pv-badge {
            display: inline-block;
            background: #F6B93B;
            color: #0E2238;
            font-weight: 800;
            font-size: 11.5px;
            letter-spacing: 0.03em;
            padding: 4px 10px;
            border-radius: 999px;
            margin-bottom: 8px;
          }
          #msNativePreviewVeil h3 {
            margin: 0 0 5px;
            font-family: ui-rounded, "SF Pro Rounded", -apple-system, sans-serif;
            font-size: 20px;
            font-weight: 900;
            color: #0E2238;
          }
          #msNativePreviewVeil p {
            margin: 0 0 14px;
            font-size: 13.5px;
            line-height: 1.42;
            color: #4E647C;
          }
          #msNativePreviewVeil button {
            appearance: none;
            border: none;
            background: #1769C2;
            color: #FFFFFF;
            font-weight: 700;
            font-size: 15px;
            padding: 12px 22px;
            border-radius: 13px;
            cursor: pointer;
            box-shadow: 0 6px 18px rgba(23,105,194,0.26);
          }
          #msNativePreviewVeil button:active {
            transform: scale(0.98);
          }
          #msSliBadge {
            display: inline-flex;
            align-items: center;
            gap: 4px;
            height: 24px;
            padding: 0 9px;
            margin-right: 6px;
            border-radius: 999px;
            background: #EAF4FE;
            border: 1px solid #D6E4F2;
            color: #0F56A3;
            font-family: ui-rounded, "SF Pro Rounded", -apple-system, sans-serif;
            font-size: 11.5px;
            font-weight: 700;
            font-variant-numeric: tabular-nums;
            white-space: nowrap;
            cursor: pointer;
          }
          #msSliBadge:active {
            background: #D8EAFC;
          }
        `;
        (document.head || document.documentElement).appendChild(style);
      }

      function currentJobId() {
        return window.__ms?.S?.job || activePreviewJobId || null;
      }

      function isCurrentScorePreviewLocked() {
        if (nativeIsPro) return false;
        const jobId = currentJobId();
        return Boolean(jobId && previewJobs.has(jobId));
      }

      function removePreviewVeil() {
        const veil = document.getElementById('msNativePreviewVeil');
        if (veil) veil.remove();
        if (document.body && document.body.classList.contains('ms-native-preview-locked')) {
          document.body.classList.remove('ms-native-preview-locked');
        }
      }

      function positionProgressivePreviewVeil(veil, scoreScroll) {
        const scoreEl = document.getElementById('score');
        const svgEl = scoreEl ? scoreEl.querySelector('svg') : null;
        const scoreTop = scoreEl ? scoreEl.offsetTop : 0;
        const scoreHeight = Math.max(
          svgEl ? svgEl.getBoundingClientRect().height : 0,
          scoreEl ? scoreEl.scrollHeight : 0,
          scoreScroll.scrollHeight - scoreTop
        );
        // Anchor progressive blur starting at ~38% down the rendered score so upper bars remain 100% crisp
        // and the lower staves transition smoothly through the 3-stage blur stack.
        const startY = Math.max(88, Math.round(scoreTop + scoreHeight * 0.36));
        const veilHeight = Math.max(250, Math.round(scoreHeight - startY + scoreTop + 36));
        veil.style.top = startY + 'px';
        veil.style.height = veilHeight + 'px';
      }

      function renderPreviewVeilIfNeeded() {
        const editor = document.getElementById('viewEditor');
        const scoreScroll = document.getElementById('scoreScroll');
        if (!editor || editor.classList.contains('hidden') || !scoreScroll) {
          removePreviewVeil();
          return;
        }
        if (!isCurrentScorePreviewLocked()) {
          removePreviewVeil();
          return;
        }
        injectStyles();
        if (!document.body.classList.contains('ms-native-preview-locked')) {
          document.body.classList.add('ms-native-preview-locked');
        }
        let veil = document.getElementById('msNativePreviewVeil');
        if (!veil) {
          veil = document.createElement('div');
          veil.id = 'msNativePreviewVeil';
          veil.innerHTML = `
            <div class="ms-pv-blur-stack" aria-hidden="true">
              <div class="ms-pv-blur-1"></div>
              <div class="ms-pv-blur-2"></div>
              <div class="ms-pv-blur-3"></div>
              <div class="ms-pv-tint"></div>
            </div>
            <div class="ms-pv-card">
              <span class="ms-pv-badge">HALF-PAGE PREVIEW</span>
              <h3>The rest of this page is blurred</h3>
              <p>You can listen to the preview bars right now. Unlock MusicScan Pro to see every bar, edit, fix flagged measures, and export.</p>
              <button type="button" id="msNativeUnlockBtn">Unlock Full Page</button>
            </div>
          `;
          veil.querySelector('#msNativeUnlockBtn').addEventListener('click', (e) => {
            e.preventDefault();
            e.stopPropagation();
            triggerNativePaywall('Unlock the full page, fix flagged bars, play back, mark up, and export to MuseScore.');
          });
          scoreScroll.appendChild(veil);
        }
        positionProgressivePreviewVeil(veil, scoreScroll);
      }

      function updateSLIBadge() {
        if (!latestSLISummary) return;
        injectStyles();
        const zoomBox = document.querySelector('#viewEditor .statusbar .zoom');
        if (!zoomBox) return;
        let badge = document.getElementById('msSliBadge');
        if (!badge) {
          badge = document.createElement('button');
          badge.id = 'msSliBadge';
          badge.type = 'button';
          badge.title = 'Scan latency (SLI) — tap to view details in Settings';
          badge.addEventListener('click', (e) => {
            e.preventDefault();
            e.stopPropagation();
            postToNativeImmediate('settings');
          });
          zoomBox.insertBefore(badge, zoomBox.firstChild);
        }
        badge.textContent = latestSLISummary;
      }

      async function triggerNativePaywall(reason) {
        if (paywallPending) return false;
        paywallPending = true;
        try {
          const res = await callNative('paywall', {
            reason: reason || 'Unlock MusicScan Pro for full pages, editing, playback, markup, and MuseScore export.',
            jobId: currentJobId() || ''
          });
          return Boolean(res && res.unlocked);
        } catch (err) {
          return false;
        } finally {
          paywallPending = false;
        }
      }

      window.__msSetNativePro = (isPro) => {
        nativeIsPro = Boolean(isPro);
        document.documentElement.classList.toggle('ms-native-pro', nativeIsPro);
        if (nativeIsPro) {
          removePreviewVeil();
        } else {
          scheduleRenderPreviewVeil();
        }
      };

      window.__msApplyUnlockedJob = (jobId, payload) => {
        if (jobId) previewJobs.delete(jobId);
        if (activePreviewJobId === jobId) activePreviewJobId = null;
        nativeIsPro = true;
        document.documentElement.classList.add('ms-native-pro');
        removePreviewVeil();

        const ms = window.__ms;
        const result = payload && payload.result;
        if (ms && result && result.xml) {
          try {
            if (ms.S) {
              ms.S.result = result;
              ms.S.job = jobId;
            }
            if (typeof ms.openScore === 'function') {
              ms.openScore(result.xml, result.measures || []);
            }
            if (ms.S) {
              ms.S.job = jobId;
              ms.S.photoPage = jobId;
            }
            const imgs = document.querySelectorAll('#photoCol img, img[src*="page.png"]');
            const bust = '?unlocked=' + Date.now();
            imgs.forEach((img) => {
              const src = img.getAttribute('src') || '';
              if (src.includes('page.png')) {
                img.src = src.split('?')[0] + bust;
              }
            });
          } catch (e) {
            console.error('Could not reload unlocked score:', e);
          }
        }
      };

      // Intercept JSON parsing for /api/jobs responses without calling response.clone().
      // Calling response.clone() + clone.json() concurrently with response.json() on large
      // multi-chunk HTTP/2 responses (~250 KB completed jobs) triggers a WebKit ReadableStream
      // tee deadlock where readPage()'s response.json() never resolves.
      function inspectJobsPayload(status, ok, url, data) {
        if (!data || typeof data !== 'object') return data;
        if (status === 402) {
          const detail = data.detail;
          if (detail && typeof detail === 'object') {
            if (detail.code === 'page_cap') {
              console.info('MusicScan monthly cap reached:', detail.message);
            }
            if (typeof detail.message === 'string') {
              return { ...data, detail: detail.message };
            }
          }
          return data;
        }
        if (!ok) {
          const isJobPoll = /api\/jobs\/[^/?#]+(?:[?#]|$)/.test(url);
          if (isJobPoll && !data.status) {
            const msg = typeof data.detail === 'string'
              ? data.detail
              : (data.detail && typeof data.detail.message === 'string'
                ? data.detail.message
                : ('Server error (' + status + ')'));
            return { ...data, status: 'error', error: msg };
          }
          return data;
        }

        // Track POST /api/jobs creation start timestamp for SLI latency metrics
        if (data.id && !data.status) {
          jobTimings.set(data.id, {
            startMs: lastPendingPostStartMs || performance.now(),
            pages: data.pages || 1
          });
        }

        // Record completed scan SLI when job poll reaches status === 'done'
        if (data.id && data.status === 'done' && !recordedSLIJobs.has(data.id)) {
          recordedSLIJobs.add(data.id);
          completedPageCounter += 1;
          const timing = jobTimings.get(data.id);
          const wallSeconds = timing
            ? Math.max(0.1, (performance.now() - timing.startMs) / 1000)
            : (typeof data.result?.seconds === 'number' ? data.result.seconds : 0);
          const omrSeconds = typeof data.result?.seconds === 'number' ? data.result.seconds : null;
          const measuresCount = data.result?.stats?.measures || (Array.isArray(data.result?.measures) ? data.result.measures.length : 0);
          const fastMode = Boolean(document.getElementById('optFast')?.checked);
          const access = data.allowance?.access || 'full';
          const title = (document.getElementById('docTitle')?.textContent || data.name || '').trim();

          const omrLabel = omrSeconds != null ? ` (GPU ${omrSeconds.toFixed(1)}s)` : '';
          latestSLISummary = `⏱ ${wallSeconds.toFixed(1)}s${omrLabel}`;
          setTimeout(updateSLIBadge, 120);
          setTimeout(updateSLIBadge, 550);

          postToNativeImmediate('scanSLI', {
            jobId: data.id,
            title,
            pageNumber: completedPageCounter,
            totalPages: timing?.pages || completedPageCounter,
            wallSeconds: Number(wallSeconds.toFixed(2)),
            omrSeconds: omrSeconds != null ? Number(omrSeconds.toFixed(2)) : null,
            measures: measuresCount,
            fastMode,
            access
          });
        }

        if (data.id && data.allowance) {
          if (data.allowance.access === 'preview') {
            previewJobs.add(data.id);
            activePreviewJobId = data.id;
            if (data.status === 'done') {
              setTimeout(renderPreviewVeilIfNeeded, 150);
              setTimeout(renderPreviewVeilIfNeeded, 600);
            }
          } else {
            previewJobs.delete(data.id);
            if (activePreviewJobId === data.id) activePreviewJobId = null;
            removePreviewVeil();
          }
        }
        return data;
      }

      const origFetch = window.fetch.bind(window);
      window.fetch = async (input, init) => {
        try {
          const url = typeof input === 'string' ? input : (input && input.url) || '';
          const method = ((init && init.method) || (input && input.method) || 'GET').toUpperCase();
          if (method === 'POST' && url.includes('api/jobs')) {
            lastPendingPostStartMs = performance.now();
          }
        } catch (_) {}
        const response = await origFetch(input, init);
        try {
          const url = typeof input === 'string' ? input : (input && input.url) || '';
          const isJobsRoute = url.includes('api/jobs') && !/\/(page\.png|original\.jpg)(?:[?#]|$)/.test(url);
          if (isJobsRoute) {
            const origJson = response.json.bind(response);
            Object.defineProperty(response, 'json', {
              configurable: true,
              writable: true,
              value: async () => {
                const data = await origJson();
                try {
                  return inspectJobsPayload(response.status, response.ok, url, data);
                } catch (_) {
                  return data;
                }
              }
            });
          }
        } catch (e) {
          // Never interfere with app fetch behavior.
        }
        return response;
      };

      // Guard editing, Fix It, Rescan, Ink, and Export on server-enforced preview scores,
      // while allowing Playback (#btnPlay, .pbar), Page navigation (#msPageNav, #msGoodNotesSheet, #msFollowPlayBtn), Photo view, and Zoom.
      const ALLOWED_PREVIEW_SELECTORS = '#btnNew, #btnPhoto, #photoCol, #zoomIn, #zoomOut, #zoomVal, #btnKeys, #btnPlay, #btnLoop, #btnPractice, #tempo, .tempo, .pbar, .pbar *, #practicePanel, #practicePanel *, #msPageNav, #msPageNav *, #msGoodNotesSheet, #msGoodNotesSheet *, #msFollowPlayBtn, #msFollowPlayBtn *, #msBarCompareBtn, #msMoreToolsBtn, #msSliBadge, #qualityBanner [data-b=close], #msNativePreviewVeil, #msNativePreviewVeil *, .ms-native-hdr-btn, .toast';
      function previewInteractionGuard(e) {
        if (!isCurrentScorePreviewLocked()) return;
        const editor = document.getElementById('viewEditor');
        if (!editor || editor.classList.contains('hidden')) return;
        if (!e.target.closest('#viewEditor, header.top, .pbar') || e.target.closest(ALLOWED_PREVIEW_SELECTORS)) return;
        e.preventDefault();
        e.stopImmediatePropagation();
        if (e.type === 'click') {
          triggerNativePaywall('Unlock MusicScan Pro to see the full page, edit notes, fix flagged bars, mark up, and export.');
        }
      }
      for (const evt of ['pointerdown', 'pointerup', 'click', 'dblclick']) {
        document.addEventListener(evt, previewInteractionGuard, true);
      }

      let veilRafPending = false;
      function scheduleRenderPreviewVeil() {
        if (veilRafPending) return;
        veilRafPending = true;
        requestAnimationFrame(() => {
          veilRafPending = false;
          renderPreviewVeilIfNeeded();
          updateSLIBadge();
        });
      }

      window.addEventListener('DOMContentLoaded', () => {
        const observer = new MutationObserver(() => {
          scheduleRenderPreviewVeil();
        });
        observer.observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ['class'] });
      });
    })();
    """#
}

// MARK: - Native UI Polish & Stage Bridge Script

/// Enhances the MusicScan web UI for native iOS/iPadOS & iPhone Duo feel:
/// 1. Keeps the Review & Edit tab cleanly focused on saved scans (`#library`) and live score editing.
/// 2. Fixes narrow & foldable (iPhone Duo Outer/Inner) header/toolbar layouts so nothing clips or wraps awkwardly.
/// 3. Streams screen stage, library count, fast mode, and live samples to SwiftUI tabs.
/// 4. Provides `window.__msImportFile` so native Files/PDF/MusicXML pickers feed straight into `startUpload`.
private enum NativeWebPolishScript {
    static let source = #"""
    (() => {
      if (window.__msIosPolishInstalled) return;
      window.__msIosPolishInstalled = true;

      document.documentElement.classList.add('ms-review-tab');

      const style = document.createElement('style');
      style.id = 'ms-ios-native-polish';
      style.textContent = `
        :root {
          -webkit-tap-highlight-color: transparent;
        }
        html, body {
          -webkit-font-smoothing: antialiased;
          background-color: #F5FAFF;
          overflow-x: hidden !important;
          max-width: 100vw !important;
          overscroll-behavior-x: none;
        }
        #app, #viewUpload, #viewProgress {
          overflow-x: hidden !important;
          max-width: 100% !important;
        }
        #viewUpload, #viewProgress {
          background-image: radial-gradient(rgba(23, 105, 194, 0.085) 0.75px, transparent 0.75px) !important;
          background-size: 14px 14px !important;
        }
        #viewProgress .progress-card {
          border-radius: 24px !important;
          border: 1px solid rgba(214, 228, 242, 0.95) !important;
          box-shadow: 0 2px 4px rgba(14, 34, 56, 0.04), 0 18px 40px rgba(14, 34, 56, 0.08) !important;
          background: linear-gradient(180deg, #FFFFFF 0%, #FAFDFF 100%) !important;
        }
        #viewProgress .bar {
          overflow: hidden !important;
          background: #E8F2FC !important;
        }
        #viewProgress #progressBar {
          background: linear-gradient(90deg, #1363BC 0%, #1769C2 55%, #4BA3E8 100%) !important;
          transition: width 0.32s cubic-bezier(0.22, 1, 0.36, 1) !important;
        }
        #viewProgress #progressText {
          font-variant-numeric: tabular-nums !important;
        }
        html.ms-review-tab #viewUpload .hero {
          display: none !important;
        }
        header.top, .top {
          background: rgba(245, 250, 255, 0.90) !important;
          -webkit-backdrop-filter: saturate(180%) blur(20px);
          backdrop-filter: saturate(180%) blur(20px);
          border-bottom: 1px solid rgba(214, 228, 242, 0.85) !important;
          padding-top: max(10px, env(safe-area-inset-top, 0px)) !important;
          padding-bottom: 8px !important;
          padding-left: max(14px, env(safe-area-inset-left, 0px)) !important;
          padding-right: max(14px, env(safe-area-inset-right, 0px)) !important;
          max-width: 100vw !important;
          box-sizing: border-box !important;
        }
        .drop, .sample-card, .lib-card, .card {
          border-radius: 20px !important;
          box-shadow: 0 4px 18px rgba(14, 34, 56, 0.05) !important;
          transition: transform 0.16s cubic-bezier(0.22, 1, 0.36, 1), box-shadow 0.16s ease;
        }
        .btn, button.primary, .sample-card:active, .lib-card:active {
          transition: transform 0.12s ease, opacity 0.12s ease;
        }
        .btn:active, button.primary:active {
          transform: scale(0.97);
        }
        #viewUpload {
          padding-top: 20px !important;
          padding-left: max(16px, env(safe-area-inset-left, 0px)) !important;
          padding-right: max(16px, env(safe-area-inset-right, 0px)) !important;
          padding-bottom: 28px !important;
          box-sizing: border-box !important;
        }
        #viewUpload .hero, #viewUpload .library {
          width: 100% !important;
          max-width: 820px !important;
          margin-bottom: 12px !important;
          box-sizing: border-box !important;
        }
        #viewUpload .samples {
          display: grid !important;
          grid-template-columns: repeat(auto-fill, minmax(136px, 1fr)) !important;
          gap: 12px !important;
          width: 100% !important;
        }
        #viewUpload .sample {
          width: auto !important;
        }
        .ms-native-hdr-group {
          display: inline-flex;
          align-items: center;
          gap: 6px;
          margin-left: auto;
          flex-shrink: 0;
        }
        body.editing .ms-native-hdr-group {
          margin-left: 4px;
        }
        .ms-native-hdr-btn {
          display: inline-flex;
          align-items: center;
          justify-content: center;
          gap: 5px;
          min-width: 34px;
          height: 34px;
          padding: 0 8px;
          border-radius: 999px;
          border: 1px solid rgba(23, 105, 194, 0.16);
          background: rgba(255, 255, 255, 0.88);
          color: #0F56A3;
          cursor: pointer;
          font-family: ui-rounded, "SF Pro Rounded", -apple-system, sans-serif;
          font-size: 13px;
          font-weight: 700;
          box-shadow: 0 1px 4px rgba(14, 34, 56, 0.06);
          transition: transform 0.12s ease, background 0.15s ease;
          flex-shrink: 0;
        }
        .ms-native-hdr-btn:active {
          transform: scale(0.94);
          background: #EAF4FE;
        }
        .ms-native-hdr-btn .ms-pro-dot {
          display: none;
          width: 7px;
          height: 7px;
          border-radius: 999px;
          background: #F6B93B;
          box-shadow: 0 0 0 2px rgba(246, 185, 59, 0.25);
        }
        html.ms-native-pro .ms-native-hdr-btn.ms-account-btn .ms-pro-dot {
          display: inline-block;
        }
        .ms-native-hdr-btn svg {
          width: 16px;
          height: 16px;
          stroke: currentColor;
          fill: none;
          stroke-width: 2;
          stroke-linecap: round;
          stroke-linejoin: round;
        }
        /* Adaptive Form-Factor Polish: iPhone (<=680px), iPhone Duo / Foldable (681-960px), iPad Studio (>960px) */
        @media (max-width: 680px) {
          body.editing .ms-native-hdr-group {
            display: none !important;
          }
          body.editing footer.credit {
            display: none !important;
          }
          body.editing header.top, body.editing .top {
            flex-wrap: wrap !important;
            gap: 5px !important;
            padding-top: max(6px, env(safe-area-inset-top, 0px)) !important;
            padding-bottom: 6px !important;
            padding-left: max(10px, env(safe-area-inset-left, 0px)) !important;
            padding-right: max(10px, env(safe-area-inset-right, 0px)) !important;
          }
          body.editing .top-actions {
            flex: 1 1 auto !important;
            min-width: 0 !important;
            max-width: 100% !important;
            flex-wrap: nowrap !important;
            overflow-x: auto !important;
            -webkit-overflow-scrolling: touch;
            scrollbar-width: none;
            justify-content: flex-end;
            gap: 4px !important;
            padding: 1px 0;
          }
          body.editing .top-actions::-webkit-scrollbar {
            display: none;
          }
          body.editing .top .btn,
          body.editing .top .btn.icon,
          body.editing .top .btn.play,
          body.editing #btnExport {
            height: 33px !important;
            min-width: 33px !important;
            font-size: 12.5px !important;
          }
          body.editing .top .btn.icon,
          body.editing #btnExport {
            width: 33px !important;
            padding: 0 !important;
          }
          body.editing .top .btn.play {
            width: auto !important;
            min-width: 66px !important;
            padding: 0 11px !important;
            gap: 5px !important;
            font-weight: 700 !important;
          }
          body.editing .top .btn.play .pl {
            display: inline !important;
          }
          body.editing .doc-title {
            font-size: 12.5px !important;
            padding-top: 1px;
          }
          /* Compact 1-line quality banner on iPhone so it doesn't eat half the screen */
          #qualityBanner {
            padding: 6px 10px !important;
            font-size: 12px !important;
            gap: 6px !important;
          }
          #qualityBanner ul {
            display: none !important;
          }
          /* Clean, Airy iPhone "Drag Notes" Toolbar */
          .toolbar {
            padding: 5px 8px !important;
            gap: 5px !important;
            -webkit-overflow-scrolling: touch;
          }
          .seg button {
            height: 33px !important;
            min-width: 33px !important;
            padding: 0 9px !important;
            font-size: 12.5px !important;
          }
          /* By default on iPhone, show only Drag Notes (Select), Note quick actions (when a note is selected),
             Fix It, Photo, and "More tools ▾" so the score has breathing room and isn't stuffy. */
          html.ms-form-iphone:not(.ms-iphone-full-tools) .toolbar button[data-mode="insert"],
          html.ms-form-iphone:not(.ms-iphone-full-tools) .toolbar button[data-mode="ink"],
          html.ms-form-iphone:not(.ms-iphone-full-tools) .toolbar .seg[aria-label="Note duration"],
          html.ms-form-iphone:not(.ms-iphone-full-tools) .toolbar .seg[aria-label="Note modifiers"],
          html.ms-form-iphone:not(.ms-iphone-full-tools) .toolbar .menu-wrap,
          html.ms-form-iphone:not(.ms-iphone-full-tools) .toolbar #btnSetup,
          html.ms-form-iphone:not(.ms-iphone-full-tools) .toolbar #btnRescan,
          html.ms-form-iphone:not(.ms-iphone-full-tools) .toolbar .sep {
            display: none !important;
          }
          /* Keep quick pitch/accidental/delete handy ONLY when a note is selected or full tools expanded */
          html.ms-form-iphone:not(.ms-iphone-full-tools):not(.ms-note-selected) .toolbar .seg[aria-label="Pitch and delete"] {
            display: none !important;
          }
          /* Hide the auto-popping floating bar photo inspector on iPhone unless explicitly toggled via "📷 Bar photo" */
          html.ms-form-iphone:not(.ms-iphone-show-inspector) #inspector {
            display: none !important;
          }
          html.ms-form-iphone.ms-iphone-show-inspector #inspector {
            bottom: 36px !important;
            left: 8px !important;
            right: 8px !important;
            max-width: none !important;
            padding: 6px 8px 8px !important;
            border-radius: 14px !important;
            box-shadow: 0 12px 32px rgba(14, 34, 56, 0.22) !important;
          }
          /* Stacked, clear bar analysis in Fix It on iPhone (photo strip right above the editable bar) */
          html.ms-form-iphone #review {
            padding: 8px 10px !important;
          }
          html.ms-form-iphone .rev-head {
            gap: 6px !important;
            margin-bottom: 6px !important;
          }
          html.ms-form-iphone .rev-hint {
            display: none !important;
          }
          html.ms-form-iphone .rev-crop {
            grid-template-columns: 1fr !important;
            gap: 6px !important;
          }
          html.ms-form-iphone .rev-pane canvas {
            max-height: 76px !important;
          }
          /* Hide reading crop duplicate on iPhone since the live editable SVG bar is directly underneath */
          html.ms-form-iphone .rev-crop .rev-pane:nth-child(2) {
            display: none !important;
          }
          /* Streamlined iPhone status bar */
          html.ms-form-iphone .statusbar {
            padding: 4px 10px !important;
            font-size: 11.5px !important;
          }
          html.ms-form-iphone #btnKeys,
          html.ms-form-iphone #statHint {
            display: none !important;
          }
          .lib-grid {
            grid-template-columns: repeat(auto-fill, minmax(144px, 1fr)) !important;
            gap: 10px !important;
          }
          .lib-thumb {
            height: 92px !important;
          }
          .lib-head h2 {
            font-size: 24px !important;
          }
        }
        /* iPhone Duo Inner (Unfolded 681px–960px): Split-Screen Dual-Column Score + Photo & Two-Row Studio Toolbar */
        @media (min-width: 681px) and (max-width: 960px) {
          body.editing footer.credit {
            display: none !important;
          }
          .toolbar {
            padding: 7px 12px !important;
            gap: 6px !important;
          }
          .workspace.split {
            grid-template-columns: minmax(250px, 40%) 1fr !important;
          }
          .rev-crop {
            grid-template-columns: 1fr 1fr !important;
            gap: 10px !important;
          }
          .rev-pane canvas {
            max-height: 118px !important;
          }
        }
        /* iPad Landscape / Desktop Studio (>960px): Full Notation Suite & Side-by-Side Photo Verification */
        @media (min-width: 961px) {
          .toolbar {
            padding: 8px 18px !important;
            gap: 8px !important;
          }
          .workspace.split {
            grid-template-columns: minmax(320px, 42%) 1fr !important;
          }
          .rev-crop {
            grid-template-columns: 1fr 1fr !important;
            gap: 14px !important;
          }
          .rev-pane canvas {
            max-height: 140px !important;
          }
        }
        /* Toggle chips for iPhone "More tools ▾" and on-demand "📷 Bar photo" */
        #msMoreToolsBtn {
          height: 33px;
          padding: 0 11px;
          border-radius: 10px;
          border: 1px solid #D6E4F2;
          background: #FFFFFF;
          color: #0F56A3;
          font-family: ui-rounded, "SF Pro Rounded", -apple-system, sans-serif;
          font-size: 12.5px;
          font-weight: 700;
          cursor: pointer;
          white-space: nowrap;
          flex-shrink: 0;
        }
        #msMoreToolsBtn.on {
          background: #EAF4FE;
          border-color: #1769C2;
          color: #0F56A3;
        }
        html:not(.ms-form-iphone) #msMoreToolsBtn {
          display: none !important;
        }
        #msBarCompareBtn {
          display: none;
          align-items: center;
          gap: 4px;
          height: 24px;
          padding: 0 9px;
          border-radius: 999px;
          border: 1px solid #B9D9F7;
          background: #EAF4FE;
          color: #0F56A3;
          font-family: ui-rounded, "SF Pro Rounded", -apple-system, sans-serif;
          font-size: 11.5px;
          font-weight: 700;
          cursor: pointer;
          white-space: nowrap;
        }
        #msBarCompareBtn.on {
          background: #1769C2;
          border-color: #1769C2;
          color: #FFFFFF;
        }
        html.ms-form-iphone.ms-bar-selected #msBarCompareBtn {
          display: inline-flex;
        }
        .lib-card, #viewProgress .progress-card, #score svg {
          animation: msIosFadeIn 0.26s cubic-bezier(0.22, 1, 0.36, 1) both;
        }
        @keyframes msIosFadeIn {
          from { opacity: 0; transform: translateY(4px); }
          to { opacity: 1; transform: translateY(0); }
        }
        /* Multi-Page Score Navigator Bar & GoodNotes 4-Square Thumbnail Sheet */
        #msPageNav {
          display: flex;
          align-items: center;
          gap: 6px;
          margin: 4px 10px 6px;
          padding: 6px 10px;
          border-radius: 14px;
          background: rgba(234, 244, 254, 0.92);
          border: 1px solid #D6E4F2;
          backdrop-filter: saturate(180%) blur(14px);
          -webkit-backdrop-filter: saturate(180%) blur(14px);
          overflow-x: auto;
          -webkit-overflow-scrolling: touch;
          scrollbar-width: none;
          user-select: none;
          -webkit-user-select: none;
        }
        #msPageNav::-webkit-scrollbar {
          display: none;
        }
        #msPageNav.hidden {
          display: none !important;
        }
        #msPageNav .ms-pn-grid-btn {
          flex: none;
          height: 32px;
          padding: 0 10px;
          border-radius: 10px;
          border: 1px solid #B9D9F7;
          background: #FFFFFF;
          color: #0F56A3;
          font-family: ui-rounded, "SF Pro Rounded", -apple-system, sans-serif;
          font-size: 12px;
          font-weight: 800;
          display: inline-flex;
          align-items: center;
          gap: 5px;
          cursor: pointer;
          box-shadow: 0 1px 3px rgba(14, 34, 56, 0.05);
          transition: transform 0.12s ease, background 0.14s ease;
        }
        #msPageNav .ms-pn-grid-btn:active {
          transform: scale(0.95);
          background: #EAF4FE;
        }
        #msPageNav .ms-pn-grid-btn svg {
          width: 14px;
          height: 14px;
          fill: currentColor;
        }
        #msPageNav .ms-pn-step {
          flex: none;
          width: 32px;
          height: 32px;
          border-radius: 10px;
          border: 1px solid #D6E4F2;
          background: #FFFFFF;
          color: #0F56A3;
          font-size: 16px;
          font-weight: 800;
          display: inline-flex;
          align-items: center;
          justify-content: center;
          cursor: pointer;
          padding: 0;
        }
        #msPageNav .ms-pn-step:disabled {
          opacity: 0.38;
          cursor: default;
        }
        #msPageNav .ms-pn-chips {
          display: flex;
          align-items: center;
          gap: 5px;
          flex: 1 1 auto;
          overflow-x: auto;
          scrollbar-width: none;
        }
        #msPageNav .ms-pn-chips::-webkit-scrollbar {
          display: none;
        }
        #msPageNav .ms-pn-chip {
          flex: none;
          height: 32px;
          padding: 0 11px;
          border-radius: 10px;
          border: 1px solid #D6E4F2;
          background: #FFFFFF;
          color: #0E2238;
          font-family: ui-rounded, "SF Pro Rounded", -apple-system, sans-serif;
          font-size: 12.5px;
          font-weight: 700;
          display: inline-flex;
          align-items: center;
          gap: 5px;
          cursor: pointer;
          white-space: nowrap;
          transition: background 0.14s ease, color 0.14s ease, border-color 0.14s ease;
        }
        #msPageNav .ms-pn-chip .ms-pn-bars {
          font-weight: 500;
          font-size: 11px;
          opacity: 0.72;
          font-variant-numeric: tabular-nums;
        }
        #msPageNav .ms-pn-chip.on {
          background: #1769C2;
          border-color: #1769C2;
          color: #FFFFFF;
          box-shadow: 0 3px 10px rgba(23, 105, 194, 0.22);
        }
        #msPageNav .ms-pn-chip.on .ms-pn-bars {
          opacity: 0.90;
        }
        #msPageNav .ms-pn-chip.playing-page:not(.on) {
          border-color: #1769C2;
          box-shadow: inset 0 0 0 1px #1769C2;
        }
        #msPageNav .ms-pn-chip .ms-pn-flag {
          width: 6px;
          height: 6px;
          border-radius: 50%;
          background: #C2362B;
          flex: none;
        }
        #msPageNav .ms-pn-chip.on .ms-pn-flag {
          background: #F6B93B;
        }
        #msPageNav .ms-pn-add {
          flex: none;
          height: 32px;
          padding: 0 10px;
          border-radius: 10px;
          border: 1px dashed #B9D9F7;
          background: rgba(255, 255, 255, 0.75);
          color: #0F56A3;
          font-family: ui-rounded, "SF Pro Rounded", -apple-system, sans-serif;
          font-size: 12.5px;
          font-weight: 700;
          cursor: pointer;
          white-space: nowrap;
        }
        /* Intuitive "Go to Playing Bar" Floating Pill when user scrolls away during playback */
        #msFollowPlayBtn {
          position: fixed;
          bottom: 72px;
          left: 50%;
          transform: translateX(-50%);
          z-index: 60;
          display: inline-flex;
          align-items: center;
          gap: 7px;
          height: 38px;
          padding: 0 16px;
          border-radius: 999px;
          border: 1px solid rgba(255, 255, 255, 0.35);
          background: linear-gradient(135deg, #0F56A3 0%, #1769C2 100%);
          color: #FFFFFF;
          font-family: ui-rounded, "SF Pro Rounded", -apple-system, sans-serif;
          font-size: 13px;
          font-weight: 800;
          box-shadow: 0 8px 24px rgba(15, 86, 163, 0.35), 0 2px 6px rgba(14, 34, 56, 0.14);
          cursor: pointer;
          white-space: nowrap;
          transition: transform 0.18s cubic-bezier(0.22, 1, 0.36, 1), opacity 0.18s ease;
        }
        #msFollowPlayBtn.hidden {
          display: none !important;
        }
        #msFollowPlayBtn:active {
          transform: translateX(-50%) scale(0.95);
        }
        #msFollowPlayBtn .ms-fp-pulse {
          width: 8px;
          height: 8px;
          border-radius: 50%;
          background: #5EEAD4;
          box-shadow: 0 0 0 3px rgba(94, 234, 212, 0.3);
        }
        /* GoodNotes-Style 4-Square Page Grid Sheet */
        #msGoodNotesSheet {
          position: fixed;
          inset: 0;
          z-index: 120;
          background: rgba(14, 34, 56, 0.38);
          backdrop-filter: blur(8px);
          -webkit-backdrop-filter: blur(8px);
          display: flex;
          align-items: flex-end;
          justify-content: center;
          padding: 16px;
          box-sizing: border-box;
          animation: msIosFadeIn 0.2s ease both;
        }
        #msGoodNotesSheet.hidden {
          display: none !important;
        }
        #msGoodNotesSheet .ms-gn-card {
          width: 100%;
          max-width: 720px;
          max-height: 82vh;
          background: #F5FAFF;
          border: 1px solid #D6E4F2;
          border-radius: 24px;
          box-shadow: 0 22px 54px rgba(14, 34, 56, 0.26);
          display: flex;
          flex-direction: column;
          overflow: hidden;
        }
        #msGoodNotesSheet .ms-gn-head {
          display: flex;
          align-items: center;
          justify-content: space-between;
          padding: 14px 18px;
          background: rgba(255, 255, 255, 0.92);
          border-bottom: 1px solid #D6E4F2;
        }
        #msGoodNotesSheet .ms-gn-title {
          display: flex;
          align-items: center;
          gap: 8px;
          font-family: ui-rounded, "SF Pro Rounded", -apple-system, sans-serif;
          font-size: 17px;
          font-weight: 800;
          color: #0E2238;
        }
        #msGoodNotesSheet .ms-gn-title svg {
          width: 18px;
          height: 18px;
          fill: #1769C2;
        }
        #msGoodNotesSheet .ms-gn-actions {
          display: flex;
          align-items: center;
          gap: 8px;
        }
        #msGoodNotesSheet .ms-gn-btn {
          height: 34px;
          padding: 0 12px;
          border-radius: 10px;
          border: 1px solid #D6E4F2;
          background: #FFFFFF;
          color: #0F56A3;
          font-family: ui-rounded, "SF Pro Rounded", -apple-system, sans-serif;
          font-size: 13px;
          font-weight: 700;
          cursor: pointer;
        }
        #msGoodNotesSheet .ms-gn-btn.primary {
          background: #1769C2;
          border-color: #1769C2;
          color: #FFFFFF;
        }
        #msGoodNotesSheet .ms-gn-grid {
          display: grid;
          grid-template-columns: repeat(auto-fill, minmax(145px, 1fr));
          gap: 14px;
          padding: 16px;
          overflow-y: auto;
          -webkit-overflow-scrolling: touch;
        }
        #msGoodNotesSheet .ms-gn-tile {
          background: #FFFFFF;
          border: 2px solid #D6E4F2;
          border-radius: 16px;
          padding: 10px;
          display: flex;
          flex-direction: column;
          gap: 8px;
          cursor: pointer;
          position: relative;
          transition: transform 0.14s ease, border-color 0.14s ease, box-shadow 0.14s ease;
        }
        #msGoodNotesSheet .ms-gn-tile:active {
          transform: scale(0.97);
        }
        #msGoodNotesSheet .ms-gn-tile.on {
          border-color: #1769C2;
          box-shadow: 0 6px 18px rgba(23, 105, 194, 0.18);
          background: #FAFDFF;
        }
        #msGoodNotesSheet .ms-gn-thumb {
          width: 100%;
          height: 150px;
          border-radius: 10px;
          background: #F2EEE4;
          border: 1px solid rgba(14, 34, 56, 0.08);
          overflow: hidden;
          display: flex;
          align-items: center;
          justify-content: center;
          position: relative;
        }
        #msGoodNotesSheet .ms-gn-thumb img {
          width: 100%;
          height: 100%;
          object-fit: cover;
        }
        #msGoodNotesSheet .ms-gn-badge {
          position: absolute;
          top: 7px;
          left: 7px;
          min-width: 24px;
          height: 24px;
          padding: 0 7px;
          border-radius: 999px;
          background: rgba(14, 34, 56, 0.82);
          color: #FFFFFF;
          font-family: ui-rounded, "SF Pro Rounded", -apple-system, sans-serif;
          font-size: 12px;
          font-weight: 800;
          display: inline-flex;
          align-items: center;
          justify-content: center;
        }
        #msGoodNotesSheet .ms-gn-tile.on .ms-gn-badge {
          background: #1769C2;
        }
        #msGoodNotesSheet .ms-gn-playing-pill {
          position: absolute;
          bottom: 7px;
          right: 7px;
          padding: 2px 8px;
          border-radius: 999px;
          background: #0F56A3;
          color: #FFFFFF;
          font-size: 10.5px;
          font-weight: 800;
        }
        #msGoodNotesSheet .ms-gn-meta {
          display: flex;
          align-items: center;
          justify-content: space-between;
          gap: 4px;
        }
        #msGoodNotesSheet .ms-gn-info {
          display: flex;
          flex-direction: column;
          min-width: 0;
        }
        #msGoodNotesSheet .ms-gn-name {
          font-family: ui-rounded, "SF Pro Rounded", -apple-system, sans-serif;
          font-size: 13.5px;
          font-weight: 800;
          color: #0E2238;
        }
        #msGoodNotesSheet .ms-gn-bars {
          font-size: 11.5px;
          color: #4A6078;
          font-variant-numeric: tabular-nums;
        }
        #msGoodNotesSheet .ms-gn-reorder {
          display: inline-flex;
          align-items: center;
          gap: 3px;
        }
        #msGoodNotesSheet .ms-gn-move {
          width: 26px;
          height: 26px;
          border-radius: 7px;
          border: 1px solid #D6E4F2;
          background: #F5FAFF;
          color: #0F56A3;
          font-size: 12px;
          font-weight: 800;
          display: inline-flex;
          align-items: center;
          justify-content: center;
          cursor: pointer;
          padding: 0;
        }
        #msGoodNotesSheet .ms-gn-move:disabled {
          opacity: 0.32;
          cursor: default;
        }
      `;
      (document.head || document.documentElement).appendChild(style);

      window.__msSetReviewTabMode = (enabled) => {
        document.documentElement.classList.toggle('ms-review-tab', Boolean(enabled));
      };

      function b64ToFile(b64, name, mime) {
        const bin = atob(b64);
        const bytes = new Uint8Array(bin.length);
        for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
        return new File([bytes], name || 'score', { type: mime || 'application/octet-stream' });
      }

      window.__msImportFile = (name, mime, b64) => {
        try {
          const file = b64ToFile(b64, name, mime);
          const input = document.getElementById('fileInput');
          if (!input) return false;
          const dt = new DataTransfer();
          dt.items.add(file);
          input.files = dt.files;
          input.dispatchEvent(new Event('change', { bubbles: true }));
          return true;
        } catch (err) {
          console.error('Native file import failed:', err);
          return false;
        }
      };

      function updateFormFactorClass() {
        const w = window.innerWidth || document.documentElement.clientWidth || 393;
        const root = document.documentElement;
        root.classList.toggle('ms-form-iphone', w <= 680);
        root.classList.toggle('ms-form-duo', w > 680 && w <= 960);
        root.classList.toggle('ms-form-ipad', w > 960);
        const selectBtn = document.querySelector('.toolbar button[data-mode="select"]');
        if (selectBtn) {
          selectBtn.textContent = w <= 680 ? '↖ Drag notes' : '↖ Select';
        }
      }
      updateFormFactorClass();
      window.addEventListener('resize', updateFormFactorClass, { passive: true });
      window.addEventListener('orientationchange', () => setTimeout(updateFormFactorClass, 120), { passive: true });

      // Intercept postMessage({ cmd: 'scan' }) when a preloaded multi-page native scan is waiting
      // so app.js's `#cameraInput` handler runs `await startUpload(f)` (Page 1) followed by
      // `for (const m of f.more) addPages(m)` (Pages 2..N in exact user-selected order).
      function installPreloadedScanHook() {
        const handler = window.webkit?.messageHandlers?.musicscan;
        if (!handler || handler.__msPreloadedHooked) return;
        const origPost = handler.postMessage.bind(handler);
        handler.postMessage = (msg) => {
          if (msg && msg.cmd === 'scan' && msg.id && window.__msPendingScanPayload) {
            const payload = window.__msPendingScanPayload;
            window.__msPendingScanPayload = null;
            setTimeout(() => {
              if (typeof window.__msNativeReply === 'function') {
                window.__msNativeReply(msg.id, payload);
              }
            }, 0);
            return;
          }
          return origPost(msg);
        };
        handler.__msPreloadedHooked = true;
      }
      installPreloadedScanHook();

      window.__msImportScannedImages = (name, firstB64, moreB64) => {
        try {
          installPreloadedScanHook();
          const extrasB64 = Array.isArray(moreB64) ? moreB64 : [];
          // Preferred path: route through #cameraInput's native scan handler in app.js
          // so Page 1 opens in the editor and Pages 2..N are sequentially appended in exact order via addPages().
          const camLabel = document.getElementById('cameraInput')?.closest('label');
          if (camLabel) {
            window.__msPendingScanPayload = {
              b64: firstB64,
              name: name || 'scan.jpg',
              pages: 1 + extrasB64.length,
              more: extrasB64
            };
            camLabel.click();
            return true;
          }

          // Fallback path if #cameraInput label is not found
          const base = (name || 'scan.jpg').replace(/\.jpg$/i, '');
          const first = b64ToFile(firstB64, name || 'scan.jpg', 'image/jpeg');
          const extras = extrasB64.map((b, i) => b64ToFile(b, `${base} p${i + 2}.jpg`, 'image/jpeg'));
          first.pages = 1 + extras.length;
          first.more = extras;
          if (typeof window.__ms?.startUpload === 'function') {
            window.__ms.startUpload(first);
            return true;
          }
          const input = document.getElementById('fileInput');
          if (!input) return false;
          const dt = new DataTransfer();
          dt.items.add(first);
          input.files = dt.files;
          input.dispatchEvent(new Event('change', { bubbles: true }));
          return true;
        } catch (err) {
          console.error('Native scan image import failed:', err);
          return false;
        }
      };

      // Ensure pressing the top-bar ▶ Play button plays continuously through all pages
      // (clearing any accidental single-bar selection when Loop is off so playback doesn't stop or start at the last bar).
      let playInterceptorInstalled = false;
      function ensureContinuousPlayBehavior() {
        if (playInterceptorInstalled) return;
        const playBtn = document.getElementById('btnPlay');
        if (!playBtn) return;
        playInterceptorInstalled = true;
        playBtn.addEventListener('click', () => {
          try {
            const ms = window.__ms;
            if (!ms || !ms.S || !ms.S.score) return;
            const isPlaying = document.body.classList.contains('playing');
            if (isPlaying) return; // Stopping playback
            const loopOn = Boolean(ms.S.loop);
            const selectedBars = ms.S.measures;
            const totalBars = ms.S.score.measures?.length || 0;
            // If Loop is off and only 1 bar is selected (e.g. from dragging a note or tapping the last bar),
            // clear the bar selection before togglePlay() reads S.measures so it plays continuously from the active page!
            if (!loopOn && selectedBars && selectedBars.size === 1) {
              const onlyBar = [...selectedBars][0];
              // If the user is at the very last bar or in single-note drag mode, play from the start of the active page (or bar 0)
              if (onlyBar >= totalBars - 1 || document.documentElement.classList.contains('ms-form-iphone')) {
                selectedBars.clear();
                const pages = getPageDescriptors();
                if (pages[activePageIndex] && activePageIndex > 0) {
                  const pageStartBar = pages[activePageIndex].lo || 0;
                  if (pageStartBar > 0) selectedBars.add(pageStartBar);
                }
              }
            }
          } catch (_) {}
        }, true);
      }

      function ensureAdaptiveEditorControls() {
        updateFormFactorClass();
        ensureContinuousPlayBehavior();

        const toolbar = document.querySelector('#viewEditor .toolbar');
        if (toolbar && !document.getElementById('msMoreToolsBtn')) {
          const btn = document.createElement('button');
          btn.id = 'msMoreToolsBtn';
          btn.type = 'button';
          btn.textContent = 'More tools ▾';
          btn.title = 'Show or hide full notation tools';
          btn.addEventListener('click', (e) => {
            e.preventDefault();
            e.stopPropagation();
            postNative({ id: 0, cmd: 'haptic', kind: 'selection' });
            const expanded = document.documentElement.classList.toggle('ms-iphone-full-tools');
            btn.classList.toggle('on', expanded);
            btn.textContent = expanded ? 'Less tools ▴' : 'More tools ▾';
          });
          toolbar.appendChild(btn);
        }

        const statusbar = document.querySelector('#viewEditor .statusbar');
        const zoomBox = statusbar?.querySelector('.zoom');
        if (statusbar && zoomBox && !document.getElementById('msBarCompareBtn')) {
          const compareBtn = document.createElement('button');
          compareBtn.id = 'msBarCompareBtn';
          compareBtn.type = 'button';
          compareBtn.textContent = '📷 Bar photo';
          compareBtn.title = 'Compare selected bar with original photo';
          compareBtn.addEventListener('click', (e) => {
            e.preventDefault();
            e.stopPropagation();
            postNative({ id: 0, cmd: 'haptic', kind: 'selection' });
            const shown = document.documentElement.classList.toggle('ms-iphone-show-inspector');
            compareBtn.classList.toggle('on', shown);
            const insp = document.getElementById('inspector');
            if (shown && insp && insp.classList.contains('hidden')) {
              // Trigger redraw of inspector for the active measure
              const ms = window.__ms;
              if (ms && typeof ms.redraw === 'function') ms.redraw();
            }
          });
          statusbar.insertBefore(compareBtn, zoomBox);
        }

        const inspClose = document.getElementById('inspClose');
        if (inspClose && !inspClose.__msHooked) {
          inspClose.__msHooked = true;
          inspClose.addEventListener('click', () => {
            document.documentElement.classList.remove('ms-iphone-show-inspector');
            document.getElementById('msBarCompareBtn')?.classList.remove('on');
          });
        }

        // Sync selection classes so iPhone shows pitch/delete pills only when a note is selected
        // and shows "📷 Bar photo" pill only when a bar is selected.
        const ms = window.__ms;
        const hasNoteSel = Boolean(ms?.S?.sel) || Boolean(document.querySelector('#overlay .sel'));
        const hasBarSel = Boolean(ms?.S?.measures?.size) || Boolean(document.querySelector('#overlay .msel'));
        document.documentElement.classList.toggle('ms-note-selected', hasNoteSel);
        document.documentElement.classList.toggle('ms-bar-selected', hasBarSel || hasNoteSel);
      }

      function postNative(payload) {
        try {
          window.webkit?.messageHandlers?.musicscan?.postMessage(payload);
        } catch (_) {}
      }

      function ensureHeaderActions() {
        const header = document.querySelector('header.top') || document.querySelector('.top');
        if (!header || document.getElementById('msNativeHeaderGroup')) return;

        const group = document.createElement('div');
        group.id = 'msNativeHeaderGroup';
        group.className = 'ms-native-hdr-group';

        const guideBtn = document.createElement('button');
        guideBtn.id = 'msNativeGuideBtn';
        guideBtn.type = 'button';
        guideBtn.className = 'ms-native-hdr-btn';
        guideBtn.setAttribute('aria-label', 'Quick Guide and Shortcuts');
        guideBtn.title = 'Quick Guide';
        guideBtn.innerHTML = '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="M9.5 9.5a2.5 2.5 0 0 1 4.9.8c0 1.7-2.4 2.1-2.4 3.5"/><circle cx="12" cy="17.2" r="0.8" fill="currentColor" stroke="none"/></svg>';
        guideBtn.addEventListener('click', (e) => {
          e.preventDefault();
          e.stopPropagation();
          postNative({ id: 0, cmd: 'haptic', kind: 'selection' });
          postNative({ id: 0, cmd: 'guide' });
        });

        const settingsBtn = document.createElement('button');
        settingsBtn.id = 'msNativeSettingsBtn';
        settingsBtn.type = 'button';
        settingsBtn.className = 'ms-native-hdr-btn ms-account-btn';
        settingsBtn.setAttribute('aria-label', 'Account and Settings');
        settingsBtn.title = 'Account & Settings';
        settingsBtn.innerHTML = '<svg viewBox="0 0 24 24"><circle cx="12" cy="8.5" r="3.5"/><path d="M5.5 19.5a6.5 6.5 0 0 1 13 0"/></svg><span class="ms-pro-dot"></span>';
        settingsBtn.addEventListener('click', (e) => {
          e.preventDefault();
          e.stopPropagation();
          postNative({ id: 0, cmd: 'haptic', kind: 'selection' });
          postNative({ id: 0, cmd: 'settings' });
        });

        group.appendChild(guideBtn);
        group.appendChild(settingsBtn);
        header.appendChild(group);
      }

      let activePageIndex = 0;
      let playingPageIndex = -1;
      let lastPageNavSignature = '';
      let scrollListenerInstalled = false;
      let playbackFollowDetached = false;
      let programmaticScrollUntil = 0;
      let origScoreScrollTo = null;

      const FOUR_SQUARE_SVG = '<svg viewBox="0 0 18 18" aria-hidden="true"><rect x="1.5" y="1.5" width="6.2" height="6.2" rx="1.6"/><rect x="10.3" y="1.5" width="6.2" height="6.2" rx="1.6"/><rect x="1.5" y="10.3" width="6.2" height="6.2" rx="1.6"/><rect x="10.3" y="10.3" width="6.2" height="6.2" rx="1.6"/></svg>';

      function computePageRangesFromState() {
        const ms = window.__ms;
        const meta = ms?.S?.meta;
        const nMeasures = ms?.S?.score?.nMeasures || ms?.S?.score?.measures?.length || 0;
        const fallbackJob = ms?.S?.job || null;
        if (!Array.isArray(meta) || nMeasures <= 0) return [];
        const ranges = [];
        for (let i = 0; i < nMeasures; i++) {
          const id = meta[i]?.page ?? fallbackJob;
          const prev = ranges[ranges.length - 1];
          if (prev && prev.id === id) {
            prev.hi = i;
          } else {
            ranges.push({ id, lo: i, hi: i });
          }
        }
        return ranges;
      }

      function getPageDescriptors() {
        const ms = window.__ms;
        const ranges = computePageRangesFromState();
        const tabsBox = document.getElementById('pageTabs');
        const tabBtns = tabsBox
          ? [...tabsBox.querySelectorAll('button:not(.add)')]
          : [];

        if (ranges.length > 1) {
          const meta = ms?.S?.meta || [];
          return ranges.map((r, idx) => {
            const flagged = meta.slice(r.lo, r.hi + 1).some((m) => m && m.level === 'bad');
            const thumbUrl = r.id ? `api/jobs/${r.id}/page.png` : '';
            return {
              index: idx,
              id: r.id,
              lo: r.lo,
              hi: r.hi,
              label: `Page ${idx + 1}`,
              bars: `${r.lo + 1}\u2013${r.hi + 1}`,
              flagged,
              active: idx === activePageIndex,
              thumbUrl,
              tabBtn: tabBtns[idx] || null
            };
          });
        }

        if (tabBtns.length > 1) {
          return tabBtns.map((btn, idx) => {
            const title = btn.getAttribute('title') || '';
            const match = title.match(/bars\s+([0-9]+)(?:[\u2013-]([0-9]+))?/i);
            const lo = match ? Math.max(0, parseInt(match[1], 10) - 1) : 0;
            const hi = match && match[2] ? Math.max(lo, parseInt(match[2], 10) - 1) : lo;
            return {
              index: idx,
              id: null,
              lo,
              hi,
              label: `Page ${idx + 1}`,
              bars: match ? (match[2] ? `${match[1]}\u2013${match[2]}` : `${match[1]}`) : '',
              flagged: btn.classList.contains('flag'),
              active: idx === activePageIndex,
              thumbUrl: '',
              tabBtn: btn
            };
          });
        }
        return [];
      }

      function getPageMarkYs() {
        const pages = getPageDescriptors();
        const measures = window.__ms?.S?.layout?.measures;
        if (pages.length > 1 && Array.isArray(measures) && measures.length > 0) {
          return pages.map((p, idx) => {
            if (idx === 0) return 0;
            const m = measures[p.lo];
            return m && typeof m.y0 === 'number' ? Math.max(0, m.y0) : 0;
          });
        }
        const overlay = document.getElementById('overlay');
        if (!overlay) return [0];
        const marks = [...overlay.querySelectorAll('g.pagemark rect')];
        const ys = [0];
        for (const r of marks) {
          const y = parseFloat(r.getAttribute('y') || '0');
          if (!Number.isNaN(y)) ys.push(Math.max(0, y));
        }
        return ys;
      }

      function performProgrammaticScoreScroll(topY) {
        const sc = document.getElementById('scoreScroll');
        if (!sc) return;
        programmaticScrollUntil = performance.now() + 550;
        const fn = origScoreScrollTo || sc.scrollTo.bind(sc);
        fn({ top: Math.max(0, topY), behavior: 'smooth' });
      }

      function updateFollowPlayButton() {
        let btn = document.getElementById('msFollowPlayBtn');
        const isPlaying = document.body.classList.contains('playing');
        if (!isPlaying || !playbackFollowDetached) {
          if (btn) btn.classList.add('hidden');
          return;
        }
        if (!btn) {
          btn = document.createElement('button');
          btn.id = 'msFollowPlayBtn';
          btn.type = 'button';
          btn.className = 'hidden';
          btn.addEventListener('click', (e) => {
            e.preventDefault();
            e.stopPropagation();
            postNative({ id: 0, cmd: 'haptic', kind: 'selection' });
            playbackFollowDetached = false;
            btn.classList.add('hidden');
            jumpToCurrentPlayingBar();
          });
          document.body.appendChild(btn);
        }
        const barText = (document.getElementById('pbarBar')?.textContent || 'Playing').trim();
        const pageSuffix = playingPageIndex >= 0 ? ` · Page ${playingPageIndex + 1}` : '';
        btn.innerHTML = `<span class="ms-fp-pulse"></span><span>Go to ${barText}${pageSuffix}</span>`;
        btn.classList.remove('hidden');
      }

      function jumpToCurrentPlayingBar() {
        const cursor = document.querySelector('#overlay rect.cursor');
        if (cursor) {
          const cy = parseFloat(cursor.getAttribute('y') || '0');
          if (!Number.isNaN(cy)) {
            performProgrammaticScoreScroll(cy - 48);
          }
        }
        if (playingPageIndex >= 0) {
          activePageIndex = playingPageIndex;
          syncPageNavigatorActiveState();
        }
      }

      function jumpToPageIndex(idx, fromUserAction = true) {
        const pages = getPageDescriptors();
        if (!pages.length) return;
        const clamped = Math.max(0, Math.min(pages.length - 1, idx));
        activePageIndex = clamped;
        const target = pages[clamped];
        postNative({ id: 0, cmd: 'haptic', kind: 'selection' });

        // If playback is running and the user explicitly jumps to a page, detach auto-follow
        // so playback never yanks them back to the playing bar!
        if (fromUserAction && document.body.classList.contains('playing')) {
          if (playingPageIndex >= 0 && clamped !== playingPageIndex) {
            playbackFollowDetached = true;
          } else if (clamped === playingPageIndex) {
            playbackFollowDetached = false;
          }
          updateFollowPlayButton();
        }

        const ys = getPageMarkYs();
        const targetY = ys[clamped] !== undefined ? Math.max(0, ys[clamped] - 28) : 0;

        if (target && target.tabBtn && !target.tabBtn.disabled) {
          programmaticScrollUntil = performance.now() + 550;
          target.tabBtn.click();
          // Also explicitly scroll #scoreScroll in case the web tab click was suppressed by our scroll guard
          performProgrammaticScoreScroll(targetY);
        } else {
          performProgrammaticScoreScroll(targetY);
        }
        syncPageNavigatorActiveState();
      }

      function syncPageNavigatorActiveState() {
        const nav = document.getElementById('msPageNav');
        if (!nav || nav.classList.contains('hidden')) return;
        const chips = [...nav.querySelectorAll('.ms-pn-chip')];
        chips.forEach((chip, i) => {
          chip.classList.toggle('on', i === activePageIndex);
          chip.classList.toggle('playing-page', document.body.classList.contains('playing') && i === playingPageIndex);
        });
        const prevBtn = nav.querySelector('[data-pn="prev"]');
        const nextBtn = nav.querySelector('[data-pn="next"]');
        if (prevBtn) prevBtn.disabled = activePageIndex <= 0;
        if (nextBtn) nextBtn.disabled = activePageIndex >= chips.length - 1;
        const activeChip = nav.querySelector('.ms-pn-chip.on');
        if (activeChip && typeof activeChip.scrollIntoView === 'function') {
          activeChip.scrollIntoView({ block: 'nearest', inline: 'center', behavior: 'smooth' });
        }
      }

      // GoodNotes-style 4-square visual Page Overview & Manager Sheet
      function openGoodNotesPageSheet() {
        postNative({ id: 0, cmd: 'haptic', kind: 'light' });
        let sheet = document.getElementById('msGoodNotesSheet');
        if (!sheet) {
          sheet = document.createElement('div');
          sheet.id = 'msGoodNotesSheet';
          sheet.className = 'hidden';
          sheet.addEventListener('click', (e) => {
            if (e.target === sheet) sheet.classList.add('hidden');
          });
          document.body.appendChild(sheet);
        }

        const renderSheet = () => {
          const pages = getPageDescriptors();
          const isPlaying = document.body.classList.contains('playing');
          sheet.innerHTML = `
            <div class="ms-gn-card" role="dialog" aria-label="Pages overview">
              <div class="ms-gn-head">
                <div class="ms-gn-title">
                  ${FOUR_SQUARE_SVG}
                  <span>Pages (${pages.length || 1})</span>
                </div>
                <div class="ms-gn-actions">
                  <button type="button" class="ms-gn-btn" data-gn="manage">Manage / Add…</button>
                  <button type="button" class="ms-gn-btn primary" data-gn="close">Done</button>
                </div>
              </div>
              <div class="ms-gn-grid">
                ${pages.map((p, i) => `
                  <div class="ms-gn-tile${i === activePageIndex ? ' on' : ''}" data-gn-idx="${i}">
                    <div class="ms-gn-thumb">
                      ${p.thumbUrl ? `<img src="${p.thumbUrl}" alt="Page ${i + 1}" loading="lazy">` : '<span>♪</span>'}
                      <span class="ms-gn-badge">${i + 1}</span>
                      ${isPlaying && i === playingPageIndex ? '<span class="ms-gn-playing-pill">▶ Playing</span>' : ''}
                    </div>
                    <div class="ms-gn-meta">
                      <div class="ms-gn-info">
                        <span class="ms-gn-name">Page ${i + 1}</span>
                        <span class="ms-gn-bars">Bars ${p.bars || '—'}${p.flagged ? ' · ⚠' : ''}</span>
                      </div>
                    </div>
                  </div>
                `).join('')}
              </div>
            </div>
          `;

          sheet.querySelector('[data-gn="close"]')?.addEventListener('click', () => {
            sheet.classList.add('hidden');
          });
          sheet.querySelector('[data-gn="manage"]')?.addEventListener('click', () => {
            sheet.classList.add('hidden');
            document.getElementById('btnPages')?.click();
          });
          sheet.querySelectorAll('[data-gn-idx]').forEach((tile) => {
            tile.addEventListener('click', () => {
              const idx = parseInt(tile.getAttribute('data-gn-idx') || '0', 10);
              sheet.classList.add('hidden');
              jumpToPageIndex(idx, true);
            });
          });
        };

        renderSheet();
        sheet.classList.remove('hidden');
      }

      function ensurePageNavigator() {
        const scoreCol = document.querySelector('#viewEditor .score-col');
        const scoreScroll = document.getElementById('scoreScroll');
        if (!scoreCol || !scoreScroll) return;

        // Hook #btnPages in the top header so tapping it opens the GoodNotes 4-square grid when multiple pages exist
        const topPagesBtn = document.getElementById('btnPages');
        if (topPagesBtn && !topPagesBtn.__msGridIconAdded) {
          topPagesBtn.__msGridIconAdded = true;
          topPagesBtn.innerHTML = `${FOUR_SQUARE_SVG}<span class="l">Pages</span>`;
        }

        if (!scrollListenerInstalled) {
          scrollListenerInstalled = true;
          origScoreScrollTo = scoreScroll.scrollTo.bind(scoreScroll);

          // Wrap scoreScroll.scrollTo so app.js's drawCursor() -> scrollToBar() never yanks the viewport
          // back while the user is freely browsing or jumped to another page during playback!
          scoreScroll.scrollTo = function(...args) {
            const isProgrammaticFromUs = performance.now() <= programmaticScrollUntil;
            if (document.body.classList.contains('playing') && playbackFollowDetached && !isProgrammaticFromUs) {
              return;
            }
            return origScoreScrollTo(...args);
          };

          // Detect genuine user touch / wheel scrolling during playback to detach auto-follow gracefully
          const onUserManualScrollIntent = () => {
            if (document.body.classList.contains('playing')) {
              playbackFollowDetached = true;
              updateFollowPlayButton();
            }
          };
          scoreScroll.addEventListener('touchmove', onUserManualScrollIntent, { passive: true });
          scoreScroll.addEventListener('wheel', onUserManualScrollIntent, { passive: true });

          scoreScroll.addEventListener('scroll', () => {
            const ys = getPageMarkYs();
            if (ys.length <= 1) return;
            const curY = scoreScroll.scrollTop + 96;
            let idx = 0;
            for (let i = 0; i < ys.length; i++) {
              if (curY >= ys[i]) idx = i;
            }
            if (idx !== activePageIndex) {
              activePageIndex = idx;
              syncPageNavigatorActiveState();
            }
          }, { passive: true });
        }

        let nav = document.getElementById('msPageNav');
        if (!nav) {
          nav = document.createElement('div');
          nav.id = 'msPageNav';
          nav.className = 'ms-page-nav hidden';
          nav.setAttribute('role', 'navigation');
          nav.setAttribute('aria-label', 'Score pages');
          scoreCol.insertBefore(nav, scoreScroll);
        }

        const pages = getPageDescriptors();
        if (pages.length <= 1) {
          nav.classList.add('hidden');
          lastPageNavSignature = '';
          return;
        }

        nav.classList.remove('hidden');
        const signature = pages.map((p) => `${p.index}:${p.bars}:${p.flagged ? 1 : 0}`).join('|');

        if (signature !== lastPageNavSignature) {
          lastPageNavSignature = signature;
          activePageIndex = Math.max(0, Math.min(pages.length - 1, activePageIndex));

          nav.innerHTML = `
            <button type="button" class="ms-pn-grid-btn" data-pn="grid" title="Open 4-square page overview">
              ${FOUR_SQUARE_SVG}
              <span>Pages</span>
            </button>
            <button type="button" class="ms-pn-step" data-pn="prev" aria-label="Previous page">‹</button>
            <div class="ms-pn-chips">
              ${pages.map((p, i) => `
                <button type="button" class="ms-pn-chip${i === activePageIndex ? ' on' : ''}" data-pn-idx="${i}">
                  <span>${p.label}</span>
                  ${p.bars ? `<span class="ms-pn-bars">(${p.bars})</span>` : ''}
                  ${p.flagged ? '<span class="ms-pn-flag" title="Contains flagged bars"></span>' : ''}
                </button>
              `).join('')}
            </div>
            <button type="button" class="ms-pn-step" data-pn="next" aria-label="Next page">›</button>
            <button type="button" class="ms-pn-add" data-pn="manage" title="Add or reorder pages">+</button>
          `;

          nav.querySelector('[data-pn="grid"]')?.addEventListener('click', (e) => {
            e.preventDefault();
            e.stopPropagation();
            openGoodNotesPageSheet();
          });
          nav.querySelector('[data-pn="prev"]')?.addEventListener('click', (e) => {
            e.preventDefault();
            e.stopPropagation();
            jumpToPageIndex(activePageIndex - 1, true);
          });
          nav.querySelector('[data-pn="next"]')?.addEventListener('click', (e) => {
            e.preventDefault();
            e.stopPropagation();
            jumpToPageIndex(activePageIndex + 1, true);
          });
          nav.querySelector('[data-pn="manage"]')?.addEventListener('click', (e) => {
            e.preventDefault();
            e.stopPropagation();
            postNative({ id: 0, cmd: 'haptic', kind: 'light' });
            document.getElementById('btnPages')?.click();
          });
          nav.querySelectorAll('[data-pn-idx]').forEach((chip) => {
            chip.addEventListener('click', (e) => {
              e.preventDefault();
              e.stopPropagation();
              const idx = parseInt(chip.getAttribute('data-pn-idx') || '0', 10);
              jumpToPageIndex(idx, true);
            });
          });
        }
        syncPageNavigatorActiveState();
      }

      function syncPageWithPlaybackCursor() {
        const isPlaying = document.body.classList.contains('playing');
        if (!isPlaying) {
          playingPageIndex = -1;
          if (playbackFollowDetached) {
            playbackFollowDetached = false;
            updateFollowPlayButton();
          }
          return;
        }
        const cursor = document.querySelector('#overlay rect.cursor');
        if (!cursor) return;
        const cy = parseFloat(cursor.getAttribute('y') || '0');
        if (Number.isNaN(cy)) return;
        const ys = getPageMarkYs();
        if (ys.length <= 1) return;
        let idx = 0;
        for (let i = 0; i < ys.length; i++) {
          if (cy + 24 >= ys[i]) idx = i;
        }
        playingPageIndex = idx;
        updateFollowPlayButton();

        // Only auto-advance the user's activePageIndex if they haven't manually scrolled or jumped to another page
        if (!playbackFollowDetached && idx !== activePageIndex) {
          activePageIndex = idx;
        }
        syncPageNavigatorActiveState();
      }

      let lastStateKey = '';
      function reportStage() {
        ensureHeaderActions();
        ensureAdaptiveEditorControls();
        ensurePageNavigator();
        syncPageWithPlaybackCursor();
        const isHidden = (el) => !el || el.classList.contains('hidden') || el.hidden || getComputedStyle(el).display === 'none';
        const upload = document.getElementById('viewUpload');
        const progress = document.getElementById('viewProgress');
        const editor = document.getElementById('viewEditor');

        let stage = 'home';
        if (editor && !isHidden(editor)) {
          stage = 'editor';
        } else if (progress && !isHidden(progress)) {
          stage = 'reading';
        } else if (upload && !isHidden(upload)) {
          stage = 'home';
        }

        const titleEl = document.querySelector('.doc-title');
        const title = titleEl ? (titleEl.textContent || '').trim() : '';
        const editing = document.body.classList.contains('editing');
        const playing = document.body.classList.contains('playing');
        const libraryCount = document.querySelectorAll('#library .lib-card').length;
        const libraryReady = Boolean(window.__msLibraryReady || libraryCount > 0 || stage !== 'home');
        const hasResume = Boolean(document.getElementById('resume'));
        const modalEl = document.getElementById('modal');
        const modalOpen = Boolean(modalEl && !isHidden(modalEl));
        const fastMode = Boolean(document.getElementById('optFast')?.checked);
        const toastEl = document.getElementById('toast');
        const toast = (toastEl && !isHidden(toastEl)) ? (toastEl.textContent || '').trim() : '';
        const samples = [];

        const key = `${stage}|${title}|${editing}|${playing}|${libraryCount}|${libraryReady}|${hasResume}|${modalOpen}|${fastMode}|${toast}`;
        if (key === lastStateKey) return;
        lastStateKey = key;

        postNative({
          id: 0,
          cmd: 'state',
          stage,
          title,
          editing,
          playing,
          libraryCount,
          libraryReady,
          hasResume,
          modalOpen,
          fastMode,
          toast,
          samples
        });
      }

      let rafPending = false;
      function scheduleReportStage() {
        if (rafPending) return;
        rafPending = true;
        requestAnimationFrame(() => {
          rafPending = false;
          reportStage();
        });
      }

      reportStage();
      // Safety mark in case an older server bundle hasn't set __msLibraryReady yet
      setTimeout(() => {
        if (!window.__msLibraryReady) {
          window.__msLibraryReady = true;
          scheduleReportStage();
        }
      }, 650);
      const observer = new MutationObserver(() => scheduleReportStage());
      observer.observe(document.body, {
        subtree: true,
        childList: true,
        characterData: true,
        attributes: true,
        attributeFilter: ['class', 'hidden']
      });
      document.addEventListener('change', (e) => {
        if (e.target && e.target.id === 'optFast') scheduleReportStage();
      });
      window.addEventListener('ms:library-ready', scheduleReportStage);
      window.addEventListener('hashchange', scheduleReportStage);
      window.addEventListener('popstate', scheduleReportStage);
    })();
    """#
}
