import SwiftUI

/// Root Local-First Hybrid MusicScan shell combining:
/// - Offline bundled VexFlow 4 live MusicXML editor + FluidR3 sampled audio (`LocalWebSchemeHandler`)
/// - On-device score, thumbnail, bar crop, and Apple Pencil ink persistence (`LocalScoreStore`)
/// - Native SwiftUI single 44pt nav bar + 3-mode adaptive bottom dock on iPhone (`.compact`)
/// - Native SwiftUI 52pt Studio toolbar + 3-region split workspace on iPad (`.regular`)
struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @AppStorage(AppConfig.serverURLStorageKey) private var serverAddress = AppConfig.defaultServerAddress
    @AppStorage("musicScan.hasCompletedOnboarding") private var hasCompletedOnboarding = false

    @State private var auth = AuthManager.shared
    @State private var billing = BillingManager.shared
    @State private var bridge = MusicScanBridgeController()
    @State private var scoreStore = LocalScoreStore.shared

    @State private var selectedTab: AppTab = .scan
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var showWelcomeOverlay = false
    @State private var showSettings = false
    @State private var showQuickGuide = false
    @State private var reloadToken = 0

    private var serverURL: URL? {
        ServerConfig.normalizedURL(from: serverAddress)
    }

    private var hostLabel: String {
        ServerConfig.displayHost(for: serverAddress)
    }

    private var isShowingWelcome: Bool {
        !hasCompletedOnboarding || showWelcomeOverlay
    }

    /// Hide the bottom 2-tab bar whenever a score is open in the native editor (`bridge.stage == .editor`),
    /// so the single adaptive bottom dock (iPhone) or 3-region Studio split view (iPad) owns the bottom chrome.
    private var shouldHideBottomTabBar: Bool {
        selectedTab == .review && bridge.stage == .editor
    }

    private var shouldShowNativeScoreLibrary: Bool {
        selectedTab == .review
            && loadError == nil
            && bridge.stage == .home
            && !bridge.isModalOpen
            && !scoreStore.scores.isEmpty
    }

    private var shouldShowReviewEmptyState: Bool {
        selectedTab == .review
            && loadError == nil
            && bridge.stage == .home
            && !bridge.isModalOpen
            && scoreStore.scores.isEmpty
    }

    var body: some View {
        GeometryReader { geo in
            let isStudioLayout = (horizontalSizeClass == .regular && geo.size.width >= 740)
            let editorInsets = computeEditorCanvasInsets(size: geo.size, isStudioLayout: isStudioLayout)

            ZStack {
                SkyTheme.sky25
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    ZStack {
                        // Local-first WebView stays permanently mounted via musicscan-app://local/index.html?embed=native
                        if let serverURL {
                            ZStack {
                                EditorWebView(
                                    url: serverURL,
                                    reloadToken: reloadToken,
                                    isPro: billing.isPro,
                                    controller: bridge,
                                    onLoaded: {
                                        withAnimation(.easeOut(duration: 0.2)) {
                                            isLoading = false
                                            loadError = nil
                                        }
                                        bridge.setReviewTabMode(true)
                                    },
                                    onLoadError: { message in
                                        withAnimation(.easeOut(duration: 0.2)) {
                                            isLoading = false
                                            loadError = message
                                        }
                                    },
                                    onOpenSettings: {
                                        showSettings = true
                                    },
                                    onOpenGuide: {
                                        showQuickGuide = true
                                    }
                                )
                                #if os(iOS)
                                .overlay {
                                    if selectedTab == .review
                                        && bridge.stage == .editor
                                        && bridge.isNativePencilInkActive
                                        && !bridge.isModalOpen {
                                        NativePencilCanvasView(
                                            scoreID: bridge.activeScoreID,
                                            isDrawingEnabled: true
                                        )
                                    }
                                }
                                #endif
                            }
                            .padding(.top, editorInsets.top)
                            .padding(.bottom, editorInsets.bottom)
                            .padding(.leading, editorInsets.leading)
                            .padding(.trailing, editorInsets.trailing)
                            .opacity(loadError == nil ? 1 : 0)
                            .allowsHitTesting(
                                selectedTab == .review
                                && (bridge.stage == .editor || bridge.stage == .reading)
                                && loadError == nil
                            )
                            .accessibilityHidden(
                                selectedTab != .review
                                || shouldShowNativeScoreLibrary
                                || shouldShowReviewEmptyState
                                || loadError != nil
                            )
                            .accessibilityLabel("MusicScan Score Canvas")
                        } else if selectedTab == .review {
                            ConnectionErrorView(
                                message: "The server address is not valid.",
                                hostLabel: hostLabel,
                                onRetry: reloadEditor,
                                onOpenSettings: { showSettings = true }
                            )
                        }

                        // Native Score Editor Chrome (Single 44pt Nav Bar + Adaptive Bottom Dock on iPhone; 3-Region Studio on iPad)
                        if selectedTab == .review
                            && bridge.stage == .editor
                            && !bridge.isModalOpen
                            && loadError == nil {
                            ScoreEditorChromeOverlay(bridge: bridge, store: scoreStore)
                                .transition(.opacity)
                                .zIndex(4)
                        }

                        // Native Optical Music Reading Progress UI (stage == .reading)
                        if selectedTab == .review
                            && bridge.stage == .reading
                            && !bridge.isModalOpen
                            && loadError == nil {
                            NativeReadingProgressView(bridge: bridge, store: scoreStore)
                                .transition(.opacity)
                                .zIndex(4.5)
                        }

                        // Tab 2 overlays (Native Score Library / Empty State / Error)
                        if selectedTab == .review {
                            if let loadError {
                                ConnectionErrorView(
                                    message: loadError,
                                    hostLabel: hostLabel,
                                    onRetry: reloadEditor,
                                    onOpenSettings: { showSettings = true }
                                )
                                .transition(.opacity)
                            } else if shouldShowNativeScoreLibrary {
                                ScoreLibraryView(
                                    isPro: billing.isPro,
                                    bridge: bridge,
                                    store: scoreStore,
                                    onGoToScan: {
                                        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                                            selectedTab = .scan
                                        }
                                    },
                                    onOpenGuide: { showQuickGuide = true },
                                    onOpenSettings: { showSettings = true }
                                )
                                .transition(.opacity)
                            } else if shouldShowReviewEmptyState {
                                ReviewEmptyOverlayView(
                                    isPro: billing.isPro,
                                    hasSamples: !bridge.samples.isEmpty,
                                    hasResume: bridge.hasResume || !scoreStore.scores.isEmpty,
                                    onGoToScan: {
                                        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                                            selectedTab = .scan
                                        }
                                    },
                                    onResumeLastScore: {
                                        bridge.openResume()
                                    },
                                    onTrySample: {
                                        bridge.openSample(index: 0)
                                    },
                                    onOpenGuide: { showQuickGuide = true },
                                    onOpenSettings: { showSettings = true }
                                )
                                .transition(.opacity)
                            }
                        }

                        // Tab 1: Dedicated native Scan & Upload workspace (opaque Sky canvas)
                        if selectedTab == .scan {
                            ScanWorkspaceView(
                                isPro: billing.isPro,
                                isServerLoading: false,
                                loadError: serverURL == nil ? "The server address is not valid." : loadError,
                                stage: bridge.stage,
                                activeTitle: bridge.documentTitle,
                                fastMode: bridge.fastMode,
                                samples: bridge.samples,
                                onScanCamera: {
                                    bridge.triggerScan()
                                },
                                onChoosePhotos: {
                                    bridge.triggerPhotoPicker()
                                },
                                onUploadFile: {
                                    bridge.triggerImport()
                                },
                                onToggleFastMode: { enabled in
                                    bridge.setFastMode(enabled)
                                },
                                onOpenSample: { index in
                                    bridge.openSample(index: index)
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                                        selectedTab = .review
                                    }
                                },
                                onResumeEditing: {
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                                        selectedTab = .review
                                    }
                                },
                                onOpenGuide: { showQuickGuide = true },
                                onOpenSettings: { showSettings = true },
                                onRetryConnection: reloadEditor
                            )
                            .transition(.opacity)
                            .zIndex(5)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if !isShowingWelcome && !shouldHideBottomTabBar {
                        MusicScanTabBar(
                            selectedTab: $selectedTab,
                            stage: bridge.stage,
                            libraryCount: max(scoreStore.scores.count, bridge.libraryCount),
                            onReselectReview: {
                                if bridge.stage == .editor {
                                    bridge.showLibraryHome()
                                }
                            }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.28, dampingFraction: 0.88), value: shouldHideBottomTabBar)
                .animation(.spring(response: 0.28, dampingFraction: 0.88), value: bridge.editorMode)
                .animation(.spring(response: 0.28, dampingFraction: 0.88), value: bridge.showiPadPhotoPane)
                .animation(.easeOut(duration: 0.22), value: shouldShowNativeScoreLibrary)
                .animation(.easeOut(duration: 0.22), value: shouldShowReviewEmptyState)
                .animation(.easeOut(duration: 0.22), value: bridge.preparingMessage != nil)

                if let preparing = bridge.preparingMessage, !isShowingWelcome {
                    PreparingImportOverlayView(
                        message: preparing,
                        progress: bridge.preparingProgress
                    )
                    .transition(.opacity)
                    .zIndex(14)
                }

                if let toast = bridge.toastMessage,
                   !isShowingWelcome,
                   (selectedTab == .scan || shouldShowReviewEmptyState || shouldShowNativeScoreLibrary) {
                    VStack {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(SkyTheme.blue600)
                            Text(toast)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(SkyTheme.navy900)
                                .lineLimit(3)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().stroke(SkyTheme.sky200, lineWidth: 1))
                        .shadow(color: SkyTheme.navy900.opacity(0.10), radius: 12, y: 4)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
                    .zIndex(15)
                }

                if isShowingWelcome {
                    WelcomeFlowView {
                        withAnimation(.easeOut(duration: 0.25)) {
                            hasCompletedOnboarding = true
                            showWelcomeOverlay = false
                        }
                    }
                    .transition(.opacity)
                    .zIndex(20)
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheetView(
                currentAddress: serverAddress,
                onSave: { newAddress in
                    serverAddress = newAddress
                    billing.updateServerURL(ServerConfig.normalizedURL(from: newAddress))
                },
                onReload: reloadEditor,
                onReplayWelcome: {
                    showWelcomeOverlay = true
                }
            )
            #if os(iOS)
            .modifier(PageSheetSizingModifier())
            #endif
        }
        .sheet(isPresented: $showQuickGuide) {
            QuickGuideSheetView()
        }
        .sheet(item: Binding(
            get: { billing.fallbackPaywallRequest },
            set: { newValue in
                if newValue == nil {
                    billing.dismissFallbackPaywall(unlocked: false)
                }
            }
        )) { request in
            PaywallSheetView(request: request) { unlocked in
                billing.dismissFallbackPaywall(unlocked: unlocked)
                if unlocked {
                    bridge.syncProState()
                }
            }
            #if os(iOS)
            .presentationDetents([.large])
            .presentationCornerRadius(28)
            #endif
        }
        .onAppear {
            sanitizeLegacyStoredServerURL()
            billing.configure(serverURL: serverURL)
            bridge.libraryCount = scoreStore.scores.count
        }
        .onChange(of: bridge.stage) { oldStage, newStage in
            if (newStage == .reading || newStage == .editor) && oldStage != newStage {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                    selectedTab = .review
                }
            }
        }
        .onChange(of: auth.sessionRevision) { _, _ in
            reloadEditor()
        }
        .onChange(of: billing.isPro) { _, _ in
            bridge.syncProState()
        }
        .tint(SkyTheme.blue600)
    }

    private func computeEditorCanvasInsets(size: CGSize, isStudioLayout: Bool) -> EdgeInsets {
        guard selectedTab == .review && bridge.stage == .editor && !bridge.isModalOpen else {
            return EdgeInsets()
        }
        if isStudioLayout {
            let leftWidth: CGFloat = bridge.showiPadPhotoPane ? min(max(size.width * 0.27, 250), 340) : 0
            let rightWidth: CGFloat = min(max(size.width * 0.22, 236), 280)
            return EdgeInsets(top: 52, leading: leftWidth, bottom: 0, trailing: rightWidth)
        } else {
            let fixStripHeight: CGFloat
            if bridge.editorMode == .fix {
                if bridge.showFullPageInFix {
                    fixStripHeight = bridge.isFixPhotoExpanded ? 236 : 172
                } else {
                    fixStripHeight = bridge.isFixPhotoExpanded ? 164 : 124
                }
            } else {
                fixStripHeight = 0
            }
            let topBarHeight: CGFloat = 44 + fixStripHeight
            let bottomDockHeight: CGFloat = (bridge.editorMode == .play ? 62 : 104)
            return EdgeInsets(top: topBarHeight, leading: 0, bottom: bottomDockHeight, trailing: 0)
        }
    }

    private func reloadEditor() {
        loadError = nil
        isLoading = true
        reloadToken += 1
    }

    private func sanitizeLegacyStoredServerURL() {
        guard var components = URLComponents(string: serverAddress),
              let defaultHost = URL(string: AppConfig.fallbackServerURL)?.host?.lowercased(),
              components.host?.lowercased() == defaultHost,
              let queryItems = components.queryItems,
              queryItems.contains(where: { $0.name.lowercased() == "key" }) else {
            return
        }
        let filtered = queryItems.filter { $0.name.lowercased() != "key" }
        components.queryItems = filtered.isEmpty ? nil : filtered
        serverAddress = components.string ?? AppConfig.defaultServerAddress
    }
}

#if os(iOS)
private struct PageSheetSizingModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.presentationSizing(.page)
        } else {
            content
        }
    }
}
#endif

#Preview {
    ContentView()
}
