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

/// Primary mode of the native SwiftUI score editor dock (iPhone) and studio workspace (iPad).
enum EditorMode: String, CaseIterable, Identifiable, Sendable, Equatable {
    case play
    case fix
    case edit

    var id: String { rawValue }
}

/// Active note/markup tool when editing a score.
enum EditTool: String, CaseIterable, Identifiable, Sendable, Equatable {
    case drag
    case note
    case rest
    case ink

    var id: String { rawValue }

    var label: String {
        switch self {
        case .drag: return "Drag"
        case .note: return "+ Note"
        case .rest: return "Rest"
        case .ink: return "Ink"
        }
    }

    var iPadLabel: String {
        switch self {
        case .drag: return "Drag Notes"
        case .note: return "+ Add"
        case .rest: return "Rest"
        case .ink: return "Apple Pencil Ink"
        }
    }

    var systemImage: String {
        switch self {
        case .drag: return "hand.point.up.left.fill"
        case .note: return "music.note"
        case .rest: return "pause.fill"
        case .ink: return "pencil.tip"
        }
    }
}

/// Normalized bounding box for a bar on the scanned page image (0...1 coordinates).
struct PageBarOverlayBox: Identifiable, Equatable, Sendable {
    let id: Int
    let barNumber: String
    let level: String
    let rect: NormalizedCropRect
}

/// Real sample sheet-music entry exposed by the bundled/live MusicScan app (`api/samples`).
struct WebSampleItem: Identifiable, Equatable, Sendable {
    let id: Int
    let title: String
    let thumbURL: String
}

/// Bridges native SwiftUI tabs, toolbars, docks, and Studio panes to the embedded local-first `WKWebView`.
@MainActor
@Observable
final class MusicScanBridgeController {
    var stage: WorkspaceStage = .home
    var activeScoreID: String = ""
    var documentTitle: String = ""
    var isEditing: Bool = false
    var isPlaying: Bool = false
    var libraryCount: Int = 0
    var libraryReady: Bool = true
    var hasResume: Bool = false
    var isModalOpen: Bool = false
    var fastMode: Bool = false
    var samples: [WebSampleItem] = []
    var toastMessage: String?

    /// Non-nil immediately after picking photos/files while images are normalized & handed to the reader.
    var preparingMessage: String?
    var preparingProgress: Double?

    // MARK: - Live Native Editor Chrome State (iPhone Dock & iPad Studio)

    var editorMode: EditorMode = .play
    var editTool: EditTool = .drag
    var activeDuration: String = "quarter"
    var isDotted: Bool = false
    var activeAccidental: Int? = nil
    var isPianoPadVisible: Bool = false
    var isNativePencilInkActive: Bool = false
    var showiPadPhotoPane: Bool = true
    var canUndo: Bool = false
    var canRedo: Bool = false

    var tempoBPM: Int = 96
    var isLoopEnabled: Bool = false
    var currentBarIndex: Int = 0
    var currentBarNumber: String = "1"
    var totalBars: Int = 0

    var activePageIndex: Int = 0
    var pageCount: Int = 1
    var activePageJobID: String? = nil

    var flaggedCount: Int = 0
    var redFlaggedCount: Int = 0
    var activeFlagPosition: Int = 1
    var activeFlagTotal: Int = 0
    var activeFlagBarIndex: Int = 0
    var activeFlagBarNumber: String = "1"
    var activeFlagReason: String = ""
    var activeFlagLevel: String = "check"
    var activeBarCropRect: NormalizedCropRect? = nil
    var activeBarPageRect: NormalizedCropRect? = nil
    var allPageBarBoxes: [PageBarOverlayBox] = []

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
        if let first = LocalScoreStore.shared.scores.first {
            openLocalScore(first)
            return
        }
        #if os(iOS)
        coordinator?.openResumeInWeb()
        #endif
    }

    func openLocalScore(_ item: LocalScoreItem) {
        #if os(iOS)
        coordinator?.openLocalScoreInWeb(item)
        #endif
    }

    func deleteLocalScore(_ item: LocalScoreItem) {
        LocalScoreStore.shared.deleteScore(id: item.id)
        libraryCount = LocalScoreStore.shared.scores.count
        #if os(iOS)
        coordinator?.removeScoreFromWebLibrary(id: item.id)
        #endif
    }

    func renameLocalScore(_ item: LocalScoreItem, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        LocalScoreStore.shared.renameScore(id: item.id, newTitle: trimmed)
        if activeScoreID == item.id {
            documentTitle = trimmed
            #if os(iOS)
            coordinator?.renameActiveScoreInWeb(trimmed)
            #endif
        } else {
            #if os(iOS)
            coordinator?.renameLibraryScoreInWeb(id: item.id, newTitle: trimmed)
            #endif
        }
    }

    func showLibraryHome() {
        if isPlaying {
            togglePlay()
        }
        editorMode = .play
        isNativePencilInkActive = false
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

    // MARK: - Native Editor Chrome Actions

    func setEditorMode(_ mode: EditorMode) {
        editorMode = mode
        if mode != .edit {
            isNativePencilInkActive = false
        }
        #if os(iOS)
        coordinator?.setEditorModeInWeb(mode)
        #endif
    }

    func setEditTool(_ tool: EditTool) {
        editTool = tool
        if editorMode != .edit {
            editorMode = .edit
        }
        isNativePencilInkActive = (tool == .ink)
        #if os(iOS)
        coordinator?.setEditToolInWeb(tool)
        #endif
    }

    func selectDuration(_ duration: String) {
        activeDuration = duration
        if editorMode == .play {
            editorMode = .edit
        }
        #if os(iOS)
        coordinator?.triggerEditActionInWeb("dur:\(duration)")
        #endif
    }

    func toggleDot() {
        isDotted.toggle()
        #if os(iOS)
        coordinator?.triggerEditActionInWeb("dot")
        #endif
    }

    func applyAccidental(_ alter: Int) {
        activeAccidental = alter
        #if os(iOS)
        coordinator?.triggerEditActionInWeb("acc:\(alter)")
        #endif
    }

    func triggerRest() {
        #if os(iOS)
        coordinator?.triggerEditActionInWeb("rest")
        #endif
    }

    func deleteSelected() {
        #if os(iOS)
        coordinator?.triggerEditActionInWeb("delete")
        #endif
    }

    func togglePianoPad() {
        isPianoPadVisible.toggle()
        #if os(iOS)
        coordinator?.setPianoPadVisibleInWeb(isPianoPadVisible)
        #endif
    }

    func togglePlay() {
        #if os(iOS)
        coordinator?.transportInWeb(isPlaying ? "stop" : "play")
        #endif
    }

    func stopPlayback() {
        guard isPlaying else { return }
        #if os(iOS)
        coordinator?.transportInWeb("stop")
        #endif
    }

    func toggleLoop() {
        isLoopEnabled.toggle()
        #if os(iOS)
        coordinator?.transportInWeb("toggleLoop")
        #endif
    }

    func setTempo(_ bpm: Int) {
        let clamped = min(max(bpm, 36), 220)
        tempoBPM = clamped
        #if os(iOS)
        coordinator?.setTempoInWeb(clamped)
        #endif
    }

    func stepFlaggedBar(_ delta: Int) {
        if editorMode != .fix {
            editorMode = .fix
        }
        #if os(iOS)
        coordinator?.fixNavInWeb(delta < 0 ? "prev" : "next")
        #endif
    }

    func markCurrentBarLooksRight() {
        #if os(iOS)
        coordinator?.fixNavInWeb("markOK")
        #endif
    }

    func rescanActiveBar() {
        #if os(iOS)
        coordinator?.rescanActiveBarInWeb()
        #endif
    }

    func undo() {
        #if os(iOS)
        coordinator?.undoInWeb()
        #endif
    }

    func redo() {
        #if os(iOS)
        coordinator?.redoInWeb()
        #endif
    }

    func renameActiveScore(to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        documentTitle = trimmed
        if !activeScoreID.isEmpty {
            LocalScoreStore.shared.renameScore(id: activeScoreID, newTitle: trimmed)
        }
        #if os(iOS)
        coordinator?.renameActiveScoreInWeb(trimmed)
        #endif
    }

    func openPagesSheet() {
        #if os(iOS)
        coordinator?.openPagesModalInWeb()
        #endif
    }

    func stepPage(_ delta: Int) {
        let target = min(max(0, activePageIndex + delta), max(0, pageCount - 1))
        guard target != activePageIndex else { return }
        activePageIndex = target
        #if os(iOS)
        coordinator?.jumpToPageInWeb(target)
        #endif
    }

    func adjustPageEdges() {
        #if os(iOS)
        coordinator?.adjustEdgesInWeb()
        #endif
    }

    func retakePagePhoto() {
        #if os(iOS)
        coordinator?.retakePhotoInWeb()
        #endif
    }

    func openKeyTimeTranspose() {
        #if os(iOS)
        coordinator?.openKeyTimeInWeb()
        #endif
    }

    func exportScore(format: String) {
        #if os(iOS)
        coordinator?.exportScoreInWeb(format: format)
        #endif
    }

    func exportLocalScore(_ item: LocalScoreItem, format: String) {
        #if os(iOS)
        if activeScoreID == item.id && stage == .editor {
            coordinator?.exportScoreInWeb(format: format)
            return
        }
        if format == "xml", let xml = LocalScoreStore.shared.loadMusicXML(for: item.id),
           let data = xml.data(using: .utf8) {
            let safeTitle = item.cleanTitle.replacingOccurrences(of: "/", with: "-")
            coordinator?.presentDirectFileShare(
                fileName: "\(safeTitle.isEmpty ? "score" : safeTitle).musicxml",
                data: data
            )
            return
        }
        // For MIDI export of an unopened score, open it and export MIDI
        openLocalScore(item)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            coordinator?.exportScoreInWeb(format: format)
        }
        #endif
    }

    func focusBarOnPage(_ barIndex: Int) {
        currentBarIndex = barIndex
        #if os(iOS)
        coordinator?.focusBarInWeb(barIndex)
        #endif
    }
}

/// Native iOS/iPadOS shell around the local-first MusicScan web editor (`MusicScan/web.bundle`).
///
/// Serves `musicscan-app://local/index.html?embed=native` instantaneously from the app bundle via
/// `LocalWebSchemeHandler`, persisting scores on-device in `LocalScoreStore` and waking Modal only
/// for GPU OMR (`/api/jobs`, `/api/jobs/<id>/rescan`) and billing verification.
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
        config.setURLSchemeHandler(LocalWebSchemeHandler(), forURLScheme: LocalWebSchemeHandler.scheme)
        config.userContentController.add(WeakScriptMessageHandler(context.coordinator), name: "musicscan")

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        config.userContentController.addUserScript(WKUserScript(
            source: "window.MUSICSCAN_APP = { platform: 'ios', version: '\(version)', nativePaywall: true, localFirst: true };",
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
        context.coordinator.load(remoteServerURL: url, token: reloadToken)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        controller.coordinator = context.coordinator
        context.coordinator.load(remoteServerURL: url, token: reloadToken)
        context.coordinator.syncProStateIfNeeded(isPro)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler,
        PHPickerViewControllerDelegate, UIDocumentPickerDelegate,
        UIPencilInteractionDelegate {
        var parent: EditorWebView
        weak var webView: WKWebView?

        private var loadedRemoteURL: URL?
        private var loadedToken = -1
        private var isWebReady = false
        private var pendingWebDelivery: (() -> Void)?
        private var lastSyncedPro: Bool?
        private var lastWarmupAt: Date?
        private var scanRequestID = 0
        private var preferPhotoLibraryForNextScan = false
        private let selectionFeedback = UISelectionFeedbackGenerator()
        private static let audioSessionQueue = DispatchQueue(
            label: "com.musicscan.audioSession",
            qos: .userInitiated
        )

        init(_ parent: EditorWebView) {
            self.parent = parent
        }

        private func ensurePlaybackAudioSessionActive() {
            Self.audioSessionQueue.async {
                let audio = AVAudioSession.sharedInstance()
                if audio.category != .playback || !audio.categoryOptions.contains(.mixWithOthers) {
                    try? audio.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                }
                try? audio.setActive(true)
            }
        }

        func load(remoteServerURL: URL, token: Int) {
            guard let webView, remoteServerURL != loadedRemoteURL || token != loadedToken else { return }
            loadedRemoteURL = remoteServerURL
            loadedToken = token
            isWebReady = false
            BillingManager.shared.updateServerURL(remoteServerURL)

            // Instantaneously load the bundled offline web editor via musicscan-app://local/index.html?embed=native
            let localURL = LocalWebSchemeHandler.localEditorURL
            let request = URLRequest(
                url: localURL,
                cachePolicy: .reloadIgnoringLocalCacheData,
                timeoutInterval: 15
            )
            webView.load(request)

            // Configure Supabase auth in the background without blocking launch or waking Modal
            let defaultHost = URL(string: AppConfig.fallbackServerURL)?.host?.lowercased()
            if !AuthManager.shared.isConfigured || remoteServerURL.host?.lowercased() != defaultHost {
                Task { @MainActor in
                    await AuthManager.shared.bootstrapConfig(from: remoteServerURL)
                }
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

        func openLocalScoreInWeb(_ item: LocalScoreItem) {
            triggerHaptic("light")
            ensurePlaybackAudioSessionActive()
            guard let xml = LocalScoreStore.shared.loadMusicXML(for: item.id), !xml.isEmpty else {
                // Fallback to IndexedDB entry if xml file was not written yet
                deliverWhenWebReady { [weak self] in
                    self?.webView?.callAsyncJavaScript(
                        "window.MusicScanNative && window.MusicScanNative.openFromLibraryId(scoreId)",
                        arguments: ["scoreId": item.id],
                        in: nil,
                        in: .page
                    ) { _ in }
                }
                return
            }
            let metaJSON = LocalScoreStore.shared.loadMetaJSON(for: item.id) ?? "[]"
            let pagesJSON = LocalScoreStore.shared.loadPagesJSON(for: item.id) ?? "{}"
            parent.controller.activeScoreID = item.id
            parent.controller.documentTitle = item.cleanTitle
            parent.controller.tempoBPM = item.tempoBPM
            parent.controller.editorMode = .play

            deliverWhenWebReady { [weak self] in
                self?.webView?.callAsyncJavaScript(
                    """
                    if (window.MusicScanNative && typeof window.MusicScanNative.loadScore === 'function') {
                      window.MusicScanNative.loadScore({
                        id: scoreId,
                        title: title,
                        xml: xml,
                        metaJson: metaJson,
                        pagesJson: pagesJson,
                        job: job,
                        tempo: tempo
                      });
                    }
                    """,
                    arguments: [
                        "scoreId": item.id,
                        "title": item.cleanTitle,
                        "xml": xml,
                        "metaJson": metaJSON,
                        "pagesJson": pagesJSON,
                        "job": item.primaryJobID ?? "",
                        "tempo": item.tempoBPM
                    ],
                    in: nil,
                    in: .page
                ) { _ in }
            }
        }

        func removeScoreFromWebLibrary(id: String) {
            webView?.callAsyncJavaScript(
                "window.MusicScanNative && window.MusicScanNative.removeLibraryItem(scoreId)",
                arguments: ["scoreId": id],
                in: nil,
                in: .page
            ) { _ in }
        }

        func renameLibraryScoreInWeb(id: String, newTitle: String) {
            webView?.callAsyncJavaScript(
                "window.MusicScanNative && window.MusicScanNative.renameLibraryItem(scoreId, newTitle)",
                arguments: ["scoreId": id, "newTitle": newTitle],
                in: nil,
                in: .page
            ) { _ in }
        }

        func renameActiveScoreInWeb(_ newTitle: String) {
            webView?.callAsyncJavaScript(
                "window.MusicScanNative && window.MusicScanNative.renameScore(newTitle)",
                arguments: ["newTitle": newTitle],
                in: nil,
                in: .page
            ) { _ in }
        }

        func showLibraryHomeInWeb() {
            triggerHaptic("selection")
            webView?.evaluateJavaScript("""
                (() => {
                  if (window.MusicScanNative && typeof window.MusicScanNative.closeEditor === 'function') {
                    window.MusicScanNative.closeEditor();
                    return;
                  }
                  const btn = document.getElementById('btnNew');
                  if (btn && document.body.classList.contains('editing')) {
                    btn.click();
                  }
                })();
            """)
        }

        func setEditorModeInWeb(_ mode: EditorMode) {
            triggerHaptic("selection")
            webView?.callAsyncJavaScript(
                "window.MusicScanNative && window.MusicScanNative.setMode(mode)",
                arguments: ["mode": mode.rawValue],
                in: nil,
                in: .page
            ) { _ in }
        }

        func setEditToolInWeb(_ tool: EditTool) {
            triggerHaptic("selection")
            webView?.callAsyncJavaScript(
                "window.MusicScanNative && window.MusicScanNative.setEditTool(tool)",
                arguments: ["tool": tool.rawValue],
                in: nil,
                in: .page
            ) { _ in }
        }

        func triggerEditActionInWeb(_ action: String) {
            triggerHaptic("light")
            webView?.callAsyncJavaScript(
                "window.MusicScanNative && window.MusicScanNative.triggerEditAction(act)",
                arguments: ["act": action],
                in: nil,
                in: .page
            ) { _ in }
        }

        func setPianoPadVisibleInWeb(_ visible: Bool) {
            triggerHaptic("selection")
            webView?.callAsyncJavaScript(
                "window.MusicScanNative && window.MusicScanNative.setPianoPad(visible)",
                arguments: ["visible": visible],
                in: nil,
                in: .page
            ) { _ in }
        }

        func transportInWeb(_ action: String) {
            triggerHaptic("light")
            ensurePlaybackAudioSessionActive()
            webView?.callAsyncJavaScript(
                "window.MusicScanNative && window.MusicScanNative.transport(action)",
                arguments: ["action": action],
                in: nil,
                in: .page
            ) { _ in }
        }

        func setTempoInWeb(_ bpm: Int) {
            webView?.callAsyncJavaScript(
                "window.MusicScanNative && window.MusicScanNative.setTempo(bpm)",
                arguments: ["bpm": bpm],
                in: nil,
                in: .page
            ) { _ in }
        }

        func fixNavInWeb(_ direction: String) {
            triggerHaptic(direction == "markOK" ? "success" : "selection")
            webView?.callAsyncJavaScript(
                "window.MusicScanNative && window.MusicScanNative.fixNav(direction)",
                arguments: ["direction": direction],
                in: nil,
                in: .page
            ) { _ in }
        }

        func rescanActiveBarInWeb() {
            triggerHaptic("light")
            warmupServerGPU()
            webView?.evaluateJavaScript("window.MusicScanNative && window.MusicScanNative.rescanActiveBar()")
        }

        func undoInWeb() {
            triggerHaptic("light")
            webView?.evaluateJavaScript("window.MusicScanNative && window.MusicScanNative.undo()")
        }

        func redoInWeb() {
            triggerHaptic("light")
            webView?.evaluateJavaScript("window.MusicScanNative && window.MusicScanNative.redo()")
        }

        func openPagesModalInWeb() {
            triggerHaptic("light")
            webView?.evaluateJavaScript("window.MusicScanNative && window.MusicScanNative.openPagesModal()")
        }

        func jumpToPageInWeb(_ pageIndex: Int) {
            triggerHaptic("selection")
            webView?.callAsyncJavaScript(
                "window.MusicScanNative && window.MusicScanNative.jumpToPage(idx)",
                arguments: ["idx": pageIndex],
                in: nil,
                in: .page
            ) { _ in }
        }

        func adjustEdgesInWeb() {
            triggerHaptic("light")
            webView?.evaluateJavaScript("window.MusicScanNative && window.MusicScanNative.adjustEdges()")
        }

        func retakePhotoInWeb() {
            triggerHaptic("light")
            warmupServerGPU()
            webView?.evaluateJavaScript("window.MusicScanNative && window.MusicScanNative.retakePhoto()")
        }

        func openKeyTimeInWeb() {
            triggerHaptic("light")
            webView?.evaluateJavaScript("window.MusicScanNative && window.MusicScanNative.openKeyTime()")
        }

        func exportScoreInWeb(format: String) {
            triggerHaptic("light")
            webView?.callAsyncJavaScript(
                "window.MusicScanNative && window.MusicScanNative.exportScore(fmt)",
                arguments: ["fmt": format],
                in: nil,
                in: .page
            ) { _ in }
        }

        func focusBarInWeb(_ barIndex: Int) {
            triggerHaptic("selection")
            webView?.callAsyncJavaScript(
                "window.MusicScanNative && window.MusicScanNative.focusBar(mi)",
                arguments: ["mi": barIndex],
                in: nil,
                in: .page
            ) { _ in }
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
               target.scheme != LocalWebSchemeHandler.scheme {
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
            case "localScoreUpsert":
                handleLocalScoreUpsert(body)
            case "editorState":
                handleEditorStateUpdate(body)
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
                if let title = body["title"] as? String, !title.isEmpty {
                    parent.controller.documentTitle = LocalScoreItem.humanizeTitle(title)
                }
                parent.controller.isEditing = body["editing"] as? Bool ?? false
                let nowPlaying = body["playing"] as? Bool ?? false
                if nowPlaying && !parent.controller.isPlaying {
                    ensurePlaybackAudioSessionActive()
                }
                parent.controller.isPlaying = nowPlaying
                let storeCount = LocalScoreStore.shared.scores.count
                if let libCount = (body["libraryCount"] as? NSNumber)?.intValue {
                    parent.controller.libraryCount = max(storeCount, libCount)
                } else {
                    parent.controller.libraryCount = storeCount
                }
                parent.controller.libraryReady = true
                if let hasResume = body["hasResume"] as? Bool {
                    parent.controller.hasResume = hasResume || storeCount > 0
                }
                if let modalOpen = body["modalOpen"] as? Bool {
                    parent.controller.isModalOpen = modalOpen
                }
                if let fastMode = body["fastMode"] as? Bool {
                    parent.controller.fastMode = fastMode
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
                let qualityScore = (body["qualityScore"] as? NSNumber)?.intValue
                let qualityLevel = body["qualityLevel"] as? String
                let flaggedBarsCount = (body["flaggedBars"] as? NSNumber)?.intValue
                let redBarsCount = (body["redBars"] as? NSNumber)?.intValue
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
                    qualityScore: qualityScore,
                    qualityLevel: qualityLevel,
                    flaggedBarsCount: flaggedBarsCount,
                    redBarsCount: redBarsCount,
                    fastMode: fastMode,
                    accessMode: accessMode
                )
            default:
                reply(id, ["error": "Unknown command: \(cmd)"])
            }
        }

        private func handleLocalScoreUpsert(_ body: [String: Any]) {
            guard let id = body["scoreId"] as? String, !id.isEmpty,
                  let xml = body["xml"] as? String, !xml.isEmpty else {
                return
            }
            let title = body["title"] as? String ?? "Score"
            let metaJSON = body["metaJson"] as? String ?? "[]"
            let pagesJSON = body["pagesJson"] as? String ?? "{}"
            let primaryJobID = body["job"] as? String
            let pageJobIDs = (body["pageJobIds"] as? [String]) ?? (primaryJobID.map { [$0] } ?? [])
            let barsCount = (body["bars"] as? NSNumber)?.intValue ?? 0
            let partsCount = (body["parts"] as? NSNumber)?.intValue ?? 1
            let tempoBPM = (body["tempo"] as? NSNumber)?.intValue ?? 96

            LocalScoreStore.shared.upsertFromWebEditor(
                id: id,
                title: title,
                musicXML: xml,
                metaJSONString: metaJSON,
                pagesJSONString: pagesJSON,
                primaryJobID: primaryJobID,
                pageJobIDs: pageJobIDs,
                barsCount: barsCount,
                partsCount: partsCount,
                tempoBPM: tempoBPM
            )

            parent.controller.libraryCount = LocalScoreStore.shared.scores.count

            // Cache scanned page photos locally in the background so Fix-It photo comparison works 100% offline
            if !pageJobIDs.isEmpty {
                let serverURL = loadedRemoteURL ?? ServerConfig.normalizedURL(from: AppConfig.defaultServerAddress)
                Task { @MainActor in
                    await LocalScoreStore.shared.cacheRemoteJobImagesIfNeeded(
                        scoreID: id,
                        jobIDs: pageJobIDs,
                        serverBaseURL: serverURL
                    )
                }
            }
        }

        private func handleEditorStateUpdate(_ body: [String: Any]) {
            let ctrl = parent.controller
            if let scoreID = body["scoreId"] as? String, !scoreID.isEmpty {
                ctrl.activeScoreID = scoreID
            }
            if let title = body["title"] as? String, !title.isEmpty {
                ctrl.documentTitle = LocalScoreItem.humanizeTitle(title)
            }
            if let canUndo = body["canUndo"] as? Bool {
                ctrl.canUndo = canUndo
            }
            if let canRedo = body["canRedo"] as? Bool {
                ctrl.canRedo = canRedo
            }
            if let playing = body["playing"] as? Bool {
                ctrl.isPlaying = playing
            }
            if let loop = body["loop"] as? Bool {
                ctrl.isLoopEnabled = loop
            }
            if let tempo = (body["tempo"] as? NSNumber)?.intValue, tempo > 0 {
                ctrl.tempoBPM = tempo
            }
            if let dur = body["dur"] as? String, !dur.isEmpty {
                ctrl.activeDuration = dur
            }
            if let dot = body["dot"] as? Bool {
                ctrl.isDotted = dot
            }
            if let padOpen = body["padOpen"] as? Bool {
                ctrl.isPianoPadVisible = padOpen
            }
            if let totalBars = (body["totalBars"] as? NSNumber)?.intValue {
                ctrl.totalBars = totalBars
            }
            if let barIdx = (body["barIndex"] as? NSNumber)?.intValue {
                ctrl.currentBarIndex = max(0, barIdx)
            }
            if let barNum = body["barNumber"] as? String, !barNum.isEmpty {
                ctrl.currentBarNumber = barNum
            }
            if let pageIdx = (body["pageIndex"] as? NSNumber)?.intValue {
                ctrl.activePageIndex = max(0, pageIdx)
            }
            if let pageCount = (body["pageCount"] as? NSNumber)?.intValue {
                ctrl.pageCount = max(1, pageCount)
            }
            if let pageJobID = body["pageJobId"] as? String {
                ctrl.activePageJobID = pageJobID.isEmpty ? nil : pageJobID
            }
            if let flagged = (body["flaggedCount"] as? NSNumber)?.intValue {
                ctrl.flaggedCount = max(0, flagged)
            }
            if let redFlagged = (body["redFlaggedCount"] as? NSNumber)?.intValue {
                ctrl.redFlaggedCount = max(0, redFlagged)
            }
            if let flagPos = (body["flagPos"] as? NSNumber)?.intValue {
                ctrl.activeFlagPosition = max(1, flagPos)
            }
            if let flagTotal = (body["flagTotal"] as? NSNumber)?.intValue {
                ctrl.activeFlagTotal = max(0, flagTotal)
            }
            if let flagBarIdx = (body["flagBarIndex"] as? NSNumber)?.intValue {
                ctrl.activeFlagBarIndex = max(0, flagBarIdx)
            }
            if let flagBarNum = body["flagBarNumber"] as? String, !flagBarNum.isEmpty {
                ctrl.activeFlagBarNumber = flagBarNum
            }
            if let flagReason = body["flagReason"] as? String {
                ctrl.activeFlagReason = flagReason
            }
            if let flagLevel = body["flagLevel"] as? String {
                ctrl.activeFlagLevel = flagLevel
            }
            if let cropDict = body["cropRect"] as? [String: Any],
               let x = (cropDict["x"] as? NSNumber)?.doubleValue,
               let y = (cropDict["y"] as? NSNumber)?.doubleValue,
               let w = (cropDict["w"] as? NSNumber)?.doubleValue,
               let h = (cropDict["h"] as? NSNumber)?.doubleValue {
                ctrl.activeBarCropRect = NormalizedCropRect(x: x, y: y, width: w, height: h)
            } else {
                ctrl.activeBarCropRect = nil
            }
            if let pageRectDict = body["pageRect"] as? [String: Any],
               let x = (pageRectDict["x"] as? NSNumber)?.doubleValue,
               let y = (pageRectDict["y"] as? NSNumber)?.doubleValue,
               let w = (pageRectDict["w"] as? NSNumber)?.doubleValue,
               let h = (pageRectDict["h"] as? NSNumber)?.doubleValue {
                ctrl.activeBarPageRect = NormalizedCropRect(x: x, y: y, width: w, height: h)
            } else {
                ctrl.activeBarPageRect = nil
            }
            if let rawBoxes = body["pageBoxes"] as? [[String: Any]] {
                ctrl.allPageBarBoxes = rawBoxes.compactMap { item in
                    guard let mi = (item["mi"] as? NSNumber)?.intValue,
                          let x = (item["x"] as? NSNumber)?.doubleValue,
                          let y = (item["y"] as? NSNumber)?.doubleValue,
                          let w = (item["w"] as? NSNumber)?.doubleValue,
                          let h = (item["h"] as? NSNumber)?.doubleValue else {
                        return nil
                    }
                    let num = item["num"] as? String ?? "\(mi + 1)"
                    let lvl = item["level"] as? String ?? "ok"
                    return PageBarOverlayBox(
                        id: mi,
                        barNumber: num,
                        level: lvl,
                        rect: NormalizedCropRect(x: x, y: y, width: w, height: h)
                    )
                }
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
                self.parent.controller.preparingMessage = "Opening \(fileName)…"
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

                self.parent.controller.preparingMessage = "Uploading…"
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

        func presentDirectFileShare(fileName: String, data: Data) {
            let safeName = (fileName as NSString).lastPathComponent.replacingOccurrences(of: "/", with: "-")
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(safeName.isEmpty ? "score.musicxml" : safeName)
            do {
                try data.write(to: fileURL, options: .atomic)
                guard let webView else { return }
                let activity = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
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
            } catch {
                parent.controller.toastMessage = "Could not export file: \(error.localizedDescription)"
            }
        }

        private func presentShareSheet(requestID: Int, name: String, base64: String) {
            guard webView != nil, !base64.isEmpty else {
                reply(requestID, ["error": "Nothing to share."])
                return
            }
            let safeName = (name as NSString).lastPathComponent.replacingOccurrences(of: "/", with: "-")
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(safeName.isEmpty ? "score.musicxml" : safeName)

            Task.detached(priority: .userInitiated) { [weak self] in
                guard let data = Data(base64Encoded: base64) else {
                    await MainActor.run {
                        self?.reply(requestID, ["error": "Nothing to share."])
                    }
                    return
                }
                do {
                    try data.write(to: fileURL, options: .atomic)
                } catch {
                    let message = error.localizedDescription
                    await MainActor.run {
                        self?.reply(requestID, ["error": message])
                    }
                    return
                }
                await MainActor.run {
                    guard let self, let webView = self.webView else { return }
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
                    self.presenterViewController()?.present(activity, animated: true)
                }
            }
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
        config.setURLSchemeHandler(LocalWebSchemeHandler(), forURLScheme: LocalWebSchemeHandler.scheme)
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
            webView.load(URLRequest(url: LocalWebSchemeHandler.localEditorURL))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onLoaded()
        }
    }
}
#endif

// MARK: - Injected Native Server-Allowance & Superwall Paywall Sync Script

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
            if (typeof ms.openScoreFull === 'function') {
              ms.openScoreFull({
                id: ms.S?.libId,
                name: ms.S?.name,
                xml: result.xml,
                meta: result.measures || [],
                quality: result.quality,
                job: jobId
              });
            } else if (typeof ms.openScore === 'function') {
              ms.openScore(result.xml, result.measures || []);
            }
          } catch (e) {
            console.error('Could not reload unlocked score:', e);
          }
        }
      };

      function inspectJobsPayload(status, ok, url, data) {
        if (!data || typeof data !== 'object') return data;
        if (status === 402) {
          const detail = data.detail;
          if (detail && typeof detail === 'object' && typeof detail.message === 'string') {
            return { ...data, detail: detail.message };
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

        if (data.id && !data.status) {
          jobTimings.set(data.id, {
            startMs: lastPendingPostStartMs || performance.now(),
            pages: data.pages || 1
          });
        }

        if (data.id && data.status === 'done' && !recordedSLIJobs.has(data.id)) {
          recordedSLIJobs.add(data.id);
          completedPageCounter += 1;
          const timing = jobTimings.get(data.id);
          const wallSeconds = timing
            ? Math.max(0.1, (performance.now() - timing.startMs) / 1000)
            : (typeof data.result?.seconds === 'number' ? data.result.seconds : 0);
          const omrSeconds = typeof data.result?.seconds === 'number' ? data.result.seconds : null;
          const measuresArr = Array.isArray(data.result?.measures) ? data.result.measures : [];
          const measuresCount = data.result?.stats?.measures || measuresArr.length;
          const qualityScore = typeof data.result?.quality?.score === 'number' ? Math.round(data.result.quality.score) : null;
          const qualityLevel = typeof data.result?.quality?.level === 'string' ? data.result.quality.level : null;
          const flaggedBars = measuresArr.filter((m) => m && m.level && m.level !== 'ok').length;
          const redBars = measuresArr.filter((m) => m && m.level === 'bad').length;
          const fastMode = Boolean(document.getElementById('optFast')?.checked);
          const access = data.allowance?.access || 'full';
          const title = (document.getElementById('docTitle')?.textContent || data.name || '').trim();

          postToNativeImmediate('scanSLI', {
            jobId: data.id,
            title,
            pageNumber: completedPageCounter,
            totalPages: timing?.pages || completedPageCounter,
            wallSeconds: Number(wallSeconds.toFixed(2)),
            omrSeconds: omrSeconds != null ? Number(omrSeconds.toFixed(2)) : null,
            measures: measuresCount,
            qualityScore,
            qualityLevel,
            flaggedBars,
            redBars,
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
        } catch (e) {}
        return response;
      };

      let veilRafPending = false;
      function scheduleRenderPreviewVeil() {
        if (veilRafPending) return;
        veilRafPending = true;
        requestAnimationFrame(() => {
          veilRafPending = false;
          renderPreviewVeilIfNeeded();
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

// MARK: - Local-First Native Bridge & window.MusicScanNative API

private enum NativeWebPolishScript {
    static let source = #"""
    (() => {
      if (window.__msIosPolishInstalled) return;
      window.__msIosPolishInstalled = true;

      document.documentElement.classList.add('ms-review-tab');
      if (document.body) {
        document.body.classList.add('native-embed');
      }

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
        body.native-embed header.top,
        body.native-embed .top,
        body.native-embed #qualityBanner,
        body.native-embed #toolbar,
        body.native-embed #viewEditor .toolbar,
        body.native-embed #review,
        body.native-embed #inspector,
        body.native-embed .statusbar,
        body.native-embed #photoCol,
        body.native-embed #msPageNav,
        body.native-embed #msFlagNav,
        body.native-embed #msDocTitleRow,
        body.native-embed .pbar,
        body.native-embed #practicePanel {
          display: none !important;
        }
        body.native-embed #viewEditor,
        body.native-embed .workspace,
        body.native-embed .score-col {
          padding: 0 !important;
          margin: 0 !important;
          height: 100vh !important;
          max-height: 100vh !important;
          background: transparent !important;
        }
        body.native-embed #scoreScroll {
          height: 100% !important;
          padding: 12px 10px 42px !important;
          box-sizing: border-box !important;
        }
        #viewProgress {
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
      `;
      (document.head || document.documentElement).appendChild(style);

      function postNative(payload) {
        try {
          window.webkit?.messageHandlers?.musicscan?.postMessage(payload);
        } catch (_) {}
      }

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
          const base = (name || 'scan.jpg').replace(/\.jpg$/i, '');
          const first = b64ToFile(firstB64, name || 'scan.jpg', 'image/jpeg');
          const extras = extrasB64.map((b, i) => b64ToFile(b, `${base} p${i + 2}.jpg`, 'image/jpeg'));
          first.pages = 1 + extras.length;
          first.more = extras;
          if (typeof window.__ms?.startUpload === 'function') {
            window.__ms.startUpload(first);
            return true;
          }
          return false;
        } catch (err) {
          console.error('Native scan image import failed:', err);
          return false;
        }
      };

      function humanizeTimestampTitle(raw) {
        if (!raw) return raw;
        const m = String(raw).trim().match(/^Scan\s+(\d{4})-(\d{2})-(\d{2})T(\d{2})[-:](\d{2})(?:[-:](\d{2}))?$/i);
        if (!m) return raw;
        const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
        const monIdx = Math.max(0, Math.min(11, parseInt(m[2], 10) - 1));
        const day = parseInt(m[3], 10);
        return `Scan \u00b7 ${months[monIdx]} ${day}`;
      }

      // Sync active score & IndexedDB library with Swift LocalScoreStore
      let lastSyncedUpsertSignature = '';
      function syncActiveScoreToNativeStore(force = false) {
        const ms = window.__ms;
        if (!ms?.S?.score || !ms.S.libId) return;
        try {
          const xml = ms.S.score.toXML();
          const metaJson = JSON.stringify(ms.S.meta || []);
          const pagesJson = JSON.stringify(ms.S.pages || {});
          const rawTitle = (ms.S.score.title || ms.S.name || 'Score').trim();
          const title = humanizeTimestampTitle(rawTitle);
          const pageRanges = typeof ms.pageList === 'function' ? ms.pageList() : [];
          const pageJobIds = pageRanges.map((r) => r.id).filter(Boolean);
          if (!pageJobIds.length && ms.S.job) pageJobIds.push(ms.S.job);
          const sig = `${ms.S.libId}|${title}|${xml.length}|${metaJson.length}|${pageJobIds.join(',')}`;
          if (!force && sig === lastSyncedUpsertSignature) return;
          lastSyncedUpsertSignature = sig;
          postNative({
            id: 0,
            cmd: 'localScoreUpsert',
            scoreId: ms.S.libId,
            title,
            xml,
            metaJson,
            pagesJson,
            job: ms.S.job || '',
            pageJobIds,
            bars: ms.S.score.nMeasures || 0,
            parts: ms.S.score.parts?.length || 1,
            tempo: Math.round(ms.S.score.tempo?.() || 96)
          });
        } catch (err) {
          console.error('Failed to sync active score to LocalScoreStore:', err);
        }
      }

      let idbMigrated = false;
      async function migrateIndexedDBScoresOnce() {
        if (idbMigrated) return;
        const ms = window.__ms;
        if (!ms?.library?.list) return;
        idbMigrated = true;
        try {
          const items = await ms.library.list();
          for (const e of items || []) {
            if (!e || !e.id || !e.xml) continue;
            const pageJobIds = e.pages ? Object.keys(e.pages) : (e.job ? [e.job] : []);
            postNative({
              id: 0,
              cmd: 'localScoreUpsert',
              scoreId: e.id,
              title: humanizeTimestampTitle(e.name || 'Score'),
              xml: e.xml,
              metaJson: JSON.stringify(e.meta || []),
              pagesJson: JSON.stringify(e.pages || {}),
              job: e.job || '',
              pageJobIds,
              bars: e.bars || 0,
              parts: e.parts || 1,
              tempo: 96
            });
          }
        } catch (_) {}
      }

      // Hook library.save so every edit or new scan is immediately persisted in Swift LocalScoreStore
      let librarySaveHooked = false;
      function hookLibrarySave() {
        const ms = window.__ms;
        if (librarySaveHooked || !ms?.library?.save) return;
        librarySaveHooked = true;
        const origSave = ms.library.save.bind(ms.library);
        ms.library.save = (entry) => {
          const res = origSave(entry);
          setTimeout(() => syncActiveScoreToNativeStore(true), 10);
          return res;
        };
      }

      // Flagged bar helpers for native Fix-It dock & iPad Inspector
      let activeFlagBarIndex = -1;
      function getFlaggedBars() {
        const meta = window.__ms?.S?.meta;
        if (!Array.isArray(meta)) return { all: [], bad: [] };
        const all = [];
        const bad = [];
        meta.forEach((m, idx) => {
          if (!m || m.reviewed) return;
          if (m.level === 'bad') {
            bad.push(idx);
            all.push(idx);
          } else if (m.level === 'check') {
            all.push(idx);
          }
        });
        return { all, bad };
      }

      function computeBarCropAndPageRects(mi) {
        const ms = window.__ms;
        if (!ms?.S || mi < 0) return { cropRect: null, pageRect: null, pageJobId: ms?.S?.job || '' };
        const m = ms.S.meta?.[mi];
        const pid = (typeof ms.pageIdOf === 'function' ? ms.pageIdOf(mi) : m?.page) || ms.S.job || '';
        const pg = (typeof ms.pageInfo === 'function' ? ms.pageInfo(pid) : ms.S.pages?.[pid]) || ms.S.result;
        const pageSize = pg?.page_size;
        if (!m?.bbox || !Array.isArray(pageSize) || pageSize.length < 2 || pageSize[0] <= 0 || pageSize[1] <= 0) {
          return { cropRect: null, pageRect: null, pageJobId: pid || '' };
        }
        const [W, H] = pageSize;
        const [x0, y0, x1, y1] = m.bbox;
        const sys = (pg.systems || []).find((s) => s.index === m.system) || { bbox: m.bbox };

        // Normalized rect of the exact bar on the full page (for iPad Left Pane overlay)
        const pageRect = {
          x: Math.max(0, x0 / W),
          y: Math.max(0, (y0 - 6) / H),
          w: Math.min(1, Math.max(0.02, (x1 - x0) / W)),
          h: Math.min(1, Math.max(0.02, (y1 - y0 + 12) / H))
        };

        // Generous padded crop around the bar within its system row (for iPhone Fix-It inline photo strip)
        const padX = Math.max(44, (x1 - x0) * 0.28);
        const padY = 26;
        const sx = Math.max(0, x0 - padX);
        const ex = Math.min(W, x1 + padX);
        const sy = Math.max(0, Math.min(sys.bbox?.[1] ?? y0, y0) - padY);
        const ey = Math.min(H, Math.max(sys.bbox?.[3] ?? y1, y1) + padY);
        const cropRect = {
          x: sx / W,
          y: sy / H,
          w: Math.max(0.05, (ex - sx) / W),
          h: Math.max(0.04, (ey - sy) / H)
        };
        return { cropRect, pageRect, pageJobId: pid || '' };
      }

      function computePageBoxes(pageJobId) {
        const ms = window.__ms;
        if (!ms?.S?.meta) return [];
        const pid = pageJobId || ms.S.photoPage || ms.S.job;
        const pg = (typeof ms.pageInfo === 'function' ? ms.pageInfo(pid) : ms.S.pages?.[pid]) || ms.S.result;
        const pageSize = pg?.page_size;
        if (!Array.isArray(pageSize) || pageSize.length < 2 || pageSize[0] <= 0 || pageSize[1] <= 0) return [];
        const [W, H] = pageSize;
        const boxes = [];
        ms.S.meta.forEach((m, mi) => {
          const mPid = m?.page || ms.S.job;
          if (mPid !== pid || !m?.bbox || m.bbox[2] <= m.bbox[0]) return;
          const [x0, y0, x1, y1] = m.bbox;
          const num = typeof ms.barNumber === 'function' ? String(ms.barNumber(mi)) : String(mi + 1);
          boxes.push({
            mi,
            num,
            level: m.reviewed ? 'ok' : (m.level || 'ok'),
            x: Math.max(0, x0 / W),
            y: Math.max(0, (y0 - 6) / H),
            w: Math.min(1, Math.max(0.01, (x1 - x0) / W)),
            h: Math.min(1, Math.max(0.01, (y1 - y0 + 12) / H))
          });
        });
        return boxes;
      }

      function selectAndScrollToBar(mi) {
        const ms = window.__ms;
        if (!ms?.S?.score || mi < 0 || mi >= ms.S.score.nMeasures) return;
        activeFlagBarIndex = mi;
        ms.S.sel = null;
        ms.S.measures = new Set([mi]);
        ms.S.focus = mi;
        if (typeof ms.redraw === 'function') ms.redraw();
        if (typeof ms.scrollToBar === 'function') {
          ms.scrollToBar(mi);
        } else {
          const lm = ms.S.layout?.measures?.[mi];
          if (lm && typeof lm.y0 === 'number') {
            document.getElementById('scoreScroll')?.scrollTo({ top: Math.max(0, lm.y0 - 48), behavior: 'smooth' });
          }
        }
        scheduleReportStage();
      }

      // Expose window.MusicScanNative API for SwiftUI toolbars, docks & iPad Studio
      window.MusicScanNative = {
        loadScore({ id, title, xml, metaJson, pagesJson, job, tempo }) {
          const ms = window.__ms;
          if (!ms || typeof ms.openScoreFull !== 'function') return;
          let meta = [];
          let pages = null;
          try { meta = JSON.parse(metaJson || '[]'); } catch (_) { meta = []; }
          try { pages = JSON.parse(pagesJson || 'null'); } catch (_) { pages = null; }
          const primaryJob = job || (pages && Object.keys(pages)[0]) || null;
          ms.openScoreFull({
            id: id || null,
            name: title || 'Score',
            xml,
            meta,
            quality: null,
            job: primaryJob,
            pages: (pages && Object.keys(pages).length > 0) ? pages : null
          });
          if (tempo && ms.practice?.setBpm) {
            ms.practice.setBpm(Number(tempo));
          }
          scheduleReportStage();
        },

        openFromLibraryId(id) {
          const ms = window.__ms;
          if (ms && typeof ms.openFromLibrary === 'function') {
            ms.openFromLibrary(id);
            scheduleReportStage();
          }
        },

        removeLibraryItem(id) {
          const ms = window.__ms;
          if (ms?.library?.remove) {
            ms.library.remove(id).then(() => {
              if (typeof ms.renderLibrary === 'function') ms.renderLibrary();
              scheduleReportStage();
            });
          }
        },

        renameLibraryItem(id, newTitle) {
          const ms = window.__ms;
          if (!ms?.library?.get || !ms?.library?.save) return;
          ms.library.get(id).then((entry) => {
            if (!entry) return;
            entry.name = newTitle;
            ms.library.save(entry);
            if (typeof ms.renderLibrary === 'function') ms.renderLibrary();
            scheduleReportStage();
          });
        },

        renameScore(newTitle) {
          const ms = window.__ms;
          if (!ms?.S?.score || !newTitle) return;
          ms.S.name = newTitle;
          if (typeof ms.edit === 'function') {
            ms.edit(() => { ms.S.score.title = newTitle; });
          } else {
            ms.S.score.title = newTitle;
          }
          if (typeof ms.showTitle === 'function') ms.showTitle();
          syncActiveScoreToNativeStore(true);
          scheduleReportStage();
        },

        closeEditor() {
          const ms = window.__ms;
          if (!ms) return;
          if (typeof ms.stopPlay === 'function') ms.stopPlay();
          if (typeof ms.saveLocalNow === 'function') ms.saveLocalNow();
          if (typeof ms.show === 'function') ms.show('viewUpload');
          scheduleReportStage();
        },

        setMode(mode) {
          const ms = window.__ms;
          if (!ms?.S) return;
          if (mode === 'play') {
            if (typeof ms.setMode === 'function') ms.setMode('select');
          } else if (mode === 'fix') {
            if (typeof ms.setMode === 'function') ms.setMode('select');
            const { all, bad } = getFlaggedBars();
            const curSel = ms.S.measures?.size ? Math.min(...ms.S.measures) : activeFlagBarIndex;
            const target = all.includes(curSel) ? curSel : (bad[0] ?? all[0] ?? 0);
            selectAndScrollToBar(target);
          } else if (mode === 'edit') {
            if (ms.S.mode !== 'add' && ms.S.mode !== 'ink') {
              if (typeof ms.setMode === 'function') ms.setMode('select');
            }
          } else if (mode === 'ink') {
            if (typeof ms.setMode === 'function') ms.setMode('ink');
          }
          scheduleReportStage();
        },

        setEditTool(tool) {
          const ms = window.__ms;
          if (!ms?.S) return;
          if (tool === 'drag') {
            ms.S.restMode = false;
            if (typeof ms.setMode === 'function') ms.setMode('select');
          } else if (tool === 'note') {
            ms.S.restMode = false;
            if (typeof ms.setMode === 'function') ms.setMode('add');
          } else if (tool === 'rest') {
            ms.S.restMode = true;
            if (typeof ms.setMode === 'function') ms.setMode('add');
          } else if (tool === 'ink') {
            if (typeof ms.setMode === 'function') ms.setMode('ink');
          }
          scheduleReportStage();
        },

        triggerEditAction(act) {
          const ms = window.__ms;
          if (!ms) return;
          if (act.startsWith('dur:')) {
            const dur = act.slice(4);
            if (typeof ms.setDur === 'function') ms.setDur(dur);
          } else if (act.startsWith('acc:')) {
            const alter = parseInt(act.slice(4), 10);
            if (typeof ms.setAcc === 'function') ms.setAcc(alter);
          } else if (act === 'dot') {
            if (typeof ms.toggleDot === 'function') ms.toggleDot();
          } else if (act === 'rest') {
            if (typeof ms.makeRest === 'function') ms.makeRest();
          } else if (act === 'delete') {
            if (typeof ms.del === 'function') ms.del();
          }
          syncActiveScoreToNativeStore(true);
          scheduleReportStage();
        },

        setPianoPad(visible) {
          const pad = document.getElementById('notePad');
          const btnPad = document.getElementById('btnPad');
          if (!pad) return;
          const isClosed = pad.classList.contains('closed') || pad.classList.contains('hidden');
          if (Boolean(visible) === isClosed) {
            btnPad?.click();
          }
          scheduleReportStage();
        },

        transport(action) {
          const ms = window.__ms;
          if (!ms) return;
          if (action === 'play') {
            if (!document.body.classList.contains('playing')) {
              if (!ms.S?.loop && ms.S?.measures?.size === 1) {
                const onlyBar = [...ms.S.measures][0];
                const totalBars = ms.S.score?.nMeasures || 0;
                if (onlyBar >= totalBars - 1) ms.S.measures.clear();
              }
              if (typeof ms.togglePlay === 'function') ms.togglePlay();
            }
          } else if (action === 'stop') {
            if (typeof ms.stopPlay === 'function') ms.stopPlay();
          } else if (action === 'toggleLoop') {
            if (typeof ms.toggleLoop === 'function') ms.toggleLoop();
          }
          scheduleReportStage();
        },

        setTempo(bpm) {
          const ms = window.__ms;
          const tempoInput = document.getElementById('tempo');
          if (tempoInput) tempoInput.value = String(bpm);
          if (ms?.practice?.setBpm) ms.practice.setBpm(Number(bpm), true);
          scheduleReportStage();
        },

        fixNav(direction) {
          const ms = window.__ms;
          if (!ms?.S?.meta) return;
          const { all } = getFlaggedBars();
          if (!all.length) return;
          const curSel = ms.S.measures?.size ? Math.min(...ms.S.measures) : activeFlagBarIndex;

          if (direction === 'markOK') {
            const targetMi = all.includes(curSel) ? curSel : all[0];
            const m = ms.S.meta[targetMi];
            if (m) {
              m.flag = m.level;
              m.reviewed = true;
              m.level = 'ok';
              if (typeof ms.redraw === 'function') ms.redraw();
              if (typeof ms.saveLocal === 'function') ms.saveLocal();
              syncActiveScoreToNativeStore(true);
            }
            const updated = getFlaggedBars().all;
            if (updated.length > 0) {
              const nextBar = updated.find((x) => x > targetMi) ?? updated[0];
              selectAndScrollToBar(nextBar);
            } else {
              activeFlagBarIndex = -1;
              scheduleReportStage();
            }
            return;
          }

          let nextIdx = 0;
          if (direction === 'next') {
            const found = all.findIndex((x) => x > curSel);
            nextIdx = found >= 0 ? found : 0;
          } else {
            let found = -1;
            for (let i = all.length - 1; i >= 0; i--) {
              if (all[i] < curSel) { found = i; break; }
            }
            nextIdx = found >= 0 ? found : all.length - 1;
          }
          selectAndScrollToBar(all[nextIdx]);
        },

        rescanActiveBar() {
          const ms = window.__ms;
          if (!ms?.S) return;
          if (!ms.S.measures?.size && activeFlagBarIndex >= 0) {
            ms.S.measures = new Set([activeFlagBarIndex]);
          } else if (!ms.S.measures?.size) {
            ms.S.measures = new Set([0]);
          }
          if (typeof ms.rescan === 'function') ms.rescan(0);
        },

        undo() {
          const ms = window.__ms;
          if (ms && typeof ms.undo === 'function') {
            ms.undo();
            syncActiveScoreToNativeStore(true);
            scheduleReportStage();
          }
        },

        redo() {
          const ms = window.__ms;
          if (ms && typeof ms.redo === 'function') {
            ms.redo();
            syncActiveScoreToNativeStore(true);
            scheduleReportStage();
          }
        },

        openPagesModal() {
          const ms = window.__ms;
          if (ms && typeof ms.pagesDialog === 'function') ms.pagesDialog();
        },

        jumpToPage(idx) {
          const ms = window.__ms;
          if (!ms || typeof ms.pageList !== 'function') return;
          const pages = ms.pageList();
          const target = pages[Math.max(0, Math.min(pages.length - 1, idx))];
          if (target) {
            selectAndScrollToBar(target.lo || 0);
          }
        },

        adjustEdges() {
          const ms = window.__ms;
          if (ms && typeof ms.adjustEdges === 'function') ms.adjustEdges();
        },

        retakePhoto() {
          const ms = window.__ms;
          if (ms && typeof ms.retakePage === 'function') {
            ms.retakePage(ms.S?.photoPage || ms.S?.job);
          }
        },

        openKeyTime() {
          const ms = window.__ms;
          if (ms && typeof ms.keyTimeDialog === 'function') ms.keyTimeDialog();
        },

        exportScore(fmt) {
          const ms = window.__ms;
          if (ms && typeof ms.exportAs === 'function') ms.exportAs(fmt || 'xml');
        },

        focusBar(mi) {
          selectAndScrollToBar(Number(mi) || 0);
        }
      };

      let lastStateKey = '';
      let lastEditorStateKey = '';

      function reportStage() {
        if (document.body && !document.body.classList.contains('native-embed')) {
          document.body.classList.add('native-embed');
        }
        hookLibrarySave();
        migrateIndexedDBScoresOnce();

        const isHidden = (el) => !el || el.classList.contains('hidden') || el.hidden || el.style.display === 'none';
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

        const ms = window.__ms;
        const titleEl = document.querySelector('.doc-title');
        const rawTitle = (ms?.S?.score?.title || (titleEl ? titleEl.textContent : '') || ms?.S?.name || '').trim();
        const title = humanizeTimestampTitle(rawTitle);
        if (titleEl && title && titleEl.textContent !== title) {
          titleEl.textContent = title;
        }

        const editing = document.body.classList.contains('editing');
        const playing = document.body.classList.contains('playing');
        const cardCount = document.querySelectorAll('#library .lib-card').length;
        const libraryCount = cardCount || (document.body.classList.contains('has-library') ? 1 : 0);
        const libraryReady = true;
        const hasResume = Boolean(document.getElementById('resume')) || libraryCount > 0;
        const modalEl = document.getElementById('modal');
        const modalOpen = Boolean(modalEl && !isHidden(modalEl));
        const fastMode = Boolean(document.getElementById('optFast')?.checked);
        const toastEl = document.getElementById('toast');
        const toast = (toastEl && !isHidden(toastEl)) ? (toastEl.textContent || '').trim() : '';

        const key = `${stage}|${title}|${editing}|${playing}|${libraryCount}|${modalOpen}|${fastMode}|${toast}`;
        if (key !== lastStateKey) {
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
            samples: []
          });
        }

        if (stage === 'editor' && ms?.S?.score) {
          syncActiveScoreToNativeStore(false);

          const totalBars = ms.S.score.nMeasures || 0;
          const selectedBar = ms.S.measures?.size ? Math.min(...ms.S.measures) : (ms.S.focus >= 0 ? ms.S.focus : 0);
          const barIndex = Math.max(0, Math.min(Math.max(0, totalBars - 1), selectedBar));
          const barNumber = typeof ms.barNumber === 'function' ? String(ms.barNumber(barIndex)) : String(barIndex + 1);

          const { all, bad } = getFlaggedBars();
          const flagIdx = all.includes(barIndex)
            ? barIndex
            : (all.includes(activeFlagBarIndex) ? activeFlagBarIndex : (bad[0] ?? all[0] ?? barIndex));
          activeFlagBarIndex = flagIdx;
          const flagPos = Math.max(1, all.indexOf(flagIdx) + 1);
          const flagBarNumber = typeof ms.barNumber === 'function' ? String(ms.barNumber(flagIdx)) : String(flagIdx + 1);
          const flagMeta = ms.S.meta?.[flagIdx];
          const flagReason = (flagMeta && typeof ms.barReason === 'function')
            ? ms.barReason(flagMeta)
            : (flagMeta?.level === 'bad' ? 'Likely wrong rhythm or pitch' : 'Low confidence bar');
          const flagLevel = flagMeta?.level || 'check';

          const pages = typeof ms.pageList === 'function' ? ms.pageList() : [];
          const pageCount = Math.max(1, pages.length);
          let pageIndex = 0;
          for (let i = 0; i < pages.length; i++) {
            if (barIndex >= pages[i].lo && barIndex <= pages[i].hi) {
              pageIndex = i;
              break;
            }
          }

          const { cropRect, pageRect, pageJobId } = computeBarCropAndPageRects(flagIdx >= 0 ? flagIdx : barIndex);
          const activeBarRects = computeBarCropAndPageRects(barIndex);
          const pageBoxes = computePageBoxes(activeBarRects.pageJobId || pageJobId);
          const tempoInput = document.getElementById('tempo');
          const tempo = parseInt(tempoInput?.value || '96', 10) || 96;
          const padEl = document.getElementById('notePad');
          const padOpen = Boolean(padEl && !padEl.classList.contains('closed') && !padEl.classList.contains('hidden'));

          const edKey = [
            ms.S.libId || '',
            title,
            ms.S.undo?.length || 0,
            ms.S.redo?.length || 0,
            playing,
            Boolean(ms.S.loop),
            tempo,
            ms.S.dur || 'quarter',
            Boolean(ms.S.dot),
            padOpen,
            totalBars,
            barIndex,
            pageIndex,
            pageCount,
            all.length,
            bad.length,
            flagIdx,
            flagPos
          ].join('|');

          if (edKey !== lastEditorStateKey) {
            lastEditorStateKey = edKey;
            postNative({
              id: 0,
              cmd: 'editorState',
              scoreId: ms.S.libId || '',
              title,
              canUndo: Boolean(ms.S.undo?.length),
              canRedo: Boolean(ms.S.redo?.length),
              playing,
              loop: Boolean(ms.S.loop),
              tempo,
              dur: ms.S.dur || 'quarter',
              dot: Boolean(ms.S.dot),
              padOpen,
              totalBars,
              barIndex,
              barNumber,
              pageIndex,
              pageCount,
              pageJobId: activeBarRects.pageJobId || pageJobId || '',
              flaggedCount: all.length,
              redFlaggedCount: bad.length,
              flagPos,
              flagTotal: all.length,
              flagBarIndex: flagIdx,
              flagBarNumber,
              flagReason,
              flagLevel,
              cropRect,
              pageRect: activeBarRects.pageRect || pageRect,
              pageBoxes
            });
          }
        }
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
      const observer = new MutationObserver(() => scheduleReportStage());
      observer.observe(document.body, {
        subtree: true,
        childList: true,
        characterData: true,
        attributes: true,
        attributeFilter: ['class', 'hidden']
      });
      document.addEventListener('pointerup', () => setTimeout(scheduleReportStage, 30), { passive: true });
      document.addEventListener('keyup', () => setTimeout(scheduleReportStage, 30), { passive: true });
      window.addEventListener('ms:library-ready', scheduleReportStage);
    })();
    """#
}
