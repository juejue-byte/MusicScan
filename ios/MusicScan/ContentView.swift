import SwiftUI

/// Root MusicScan shell combining 100% of the real GitHub editor (`EditorWebView` + copisteria OMR +
/// VexFlow 4 live MusicXML editor + FluidR3 sampled audio + Fix It + Rescan + Adjust Edges + Ink)
/// with a super-easy 2-tab native Sky workspace (`Scan` and `Review & Edit`) tailored for
/// iPhone Duo (Outer & Inner), iPhone, and iPad.
struct ContentView: View {
    @AppStorage(AppConfig.serverURLStorageKey) private var serverAddress = AppConfig.defaultServerAddress
    @AppStorage("musicScan.hasCompletedOnboarding") private var hasCompletedOnboarding = false

    @State private var auth = AuthManager.shared
    @State private var billing = BillingManager.shared
    @State private var bridge = MusicScanBridgeController()

    @State private var selectedTab: AppTab = .scan
    @State private var isLoading = true
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

    private var shouldShowInitialConnectingSplash: Bool {
        !isShowingWelcome
            && isLoading
            && loadError == nil
            && serverURL != nil
    }

    private var shouldShowReviewSkeleton: Bool {
        selectedTab == .review
            && loadError == nil
            && serverURL != nil
            && (isLoading || (bridge.stage == .home && !bridge.libraryReady))
    }

    private var shouldShowReviewEmptyState: Bool {
        selectedTab == .review
            && !isLoading
            && bridge.libraryReady
            && loadError == nil
            && serverURL != nil
            && bridge.stage == .home
            && !bridge.isModalOpen
            && bridge.libraryCount == 0
    }

    var body: some View {
        GeometryReader { geo in
            let hideTabBarForCompactPlayback = bridge.isPlaying && geo.size.height < 640

            ZStack {
                SkyTheme.sky25
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    ZStack {
                        // Real MusicScan web workspace stays permanently mounted so cookies,
                        // IndexedDB library, WebAudio, and open edits never reset on tab switch.
                        if let serverURL {
                            EditorWebView(
                                url: serverURL,
                                reloadToken: reloadToken,
                                isPro: billing.isPro,
                                controller: bridge,
                                onLoaded: {
                                    withAnimation(.easeOut(duration: 0.25)) {
                                        isLoading = false
                                        loadError = nil
                                    }
                                    bridge.setReviewTabMode(true)
                                },
                                onLoadError: { message in
                                    withAnimation(.easeOut(duration: 0.25)) {
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
                            .ignoresSafeArea(edges: .top)
                            .opacity(loadError == nil ? 1 : 0)
                            .allowsHitTesting(selectedTab == .review && !shouldShowReviewEmptyState && loadError == nil)
                            .accessibilityHidden(
                                selectedTab != .review
                                || shouldShowReviewSkeleton
                                || shouldShowReviewEmptyState
                                || loadError != nil
                            )
                            .accessibilityLabel("MusicScan Score Editor")
                        } else if selectedTab == .review {
                            ConnectionErrorView(
                                message: "The server address is not valid.",
                                hostLabel: hostLabel,
                                onRetry: reloadEditor,
                                onOpenSettings: { showSettings = true }
                            )
                        }

                        // Tab 2 overlays (Shimmering Library Skeleton / Error / Empty Library before first scan)
                        if selectedTab == .review {
                            if shouldShowReviewSkeleton {
                                ConnectingOverlayView(
                                    hostLabel: hostLabel,
                                    isPro: billing.isPro,
                                    onOpenGuide: { showQuickGuide = true },
                                    onOpenSettings: { showSettings = true }
                                )
                                .transition(.opacity)
                            } else if let loadError {
                                ConnectionErrorView(
                                    message: loadError,
                                    hostLabel: hostLabel,
                                    onRetry: reloadEditor,
                                    onOpenSettings: { showSettings = true }
                                )
                                .transition(.opacity)
                            } else if shouldShowReviewEmptyState {
                                ReviewEmptyOverlayView(
                                    isPro: billing.isPro,
                                    hasSamples: !bridge.samples.isEmpty,
                                    hasResume: bridge.hasResume,
                                    onGoToScan: {
                                        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
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
                                isServerLoading: isLoading,
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
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                                        selectedTab = .review
                                    }
                                },
                                onResumeEditing: {
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
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

                    if !isShowingWelcome && !hideTabBarForCompactPlayback {
                        MusicScanTabBar(
                            selectedTab: $selectedTab,
                            stage: bridge.stage,
                            libraryCount: bridge.libraryCount,
                            onReselectReview: {
                                if bridge.stage == .editor {
                                    bridge.showLibraryHome()
                                }
                            }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.86), value: hideTabBarForCompactPlayback)
                .animation(.easeOut(duration: 0.24), value: shouldShowReviewSkeleton)
                .animation(.easeOut(duration: 0.24), value: shouldShowReviewEmptyState)
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
                   (selectedTab == .scan || shouldShowReviewEmptyState) {
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

                if shouldShowInitialConnectingSplash {
                    ServerLaunchSplashView(hostLabel: hostLabel)
                        .transition(.opacity)
                        .zIndex(18)
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
        }
        .onChange(of: bridge.stage) { oldStage, newStage in
            // Automatically bring the user to Review & Edit as soon as a scan/upload begins reading or opens.
            if (newStage == .reading || newStage == .editor) && oldStage != newStage {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    selectedTab = .review
                }
            }
        }
        .onChange(of: auth.sessionRevision) { _, _ in
            // Refresh WebView session cookie whenever the user signs in, links, or signs out.
            reloadEditor()
        }
        .onChange(of: billing.isPro) { _, _ in
            bridge.syncProState()
        }
        .tint(SkyTheme.blue600)
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
