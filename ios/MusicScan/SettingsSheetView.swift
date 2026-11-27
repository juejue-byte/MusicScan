import StoreKit
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case accountAndPlan = "Account and plan"
    case guide = "Guide and shortcuts"
    case server = "Reading server"
    case about = "About, terms and privacy"

    var id: String { rawValue }

    /// In App Store Release builds, hide the developer Reading Server diagnostics panel.
    static var visibleCases: [SettingsSection] {
        #if DEBUG
        allCases
        #else
        allCases.filter { $0 != .server }
        #endif
    }

    var iconName: String {
        switch self {
        case .accountAndPlan: return "person.circle.fill"
        case .guide: return "questionmark.circle.fill"
        case .server: return "server.rack"
        case .about: return "info.circle.fill"
        }
    }

    var badgeColor: Color {
        switch self {
        case .accountAndPlan: return SkyTheme.blue600
        case .guide: return SkyTheme.sureInk
        case .server: return Color(red: 0.34, green: 0.42, blue: 0.50)
        case .about: return SkyTheme.sky400
        }
    }
}

/// Real Settings experience connected directly to Supabase `AuthManager`, StoreKit 2 / Superwall
/// `BillingManager`, live server health checks, and `QuickGuideSheetView`.
/// Uses an adaptive iPad split view and native iPhone `NavigationStack` with zero fake toggles.
struct SettingsSheetView: View {
    let currentAddress: String
    let onSave: (String) -> Void
    let onReload: () -> Void
    var onReplayWelcome: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var auth = AuthManager.shared
    @State private var billing = BillingManager.shared
    @State private var sliRecorder = ScanSLIRecorder.shared
    @AppStorage(AppConfig.logoAssetStorageKey) private var selectedLogoAsset = AppConfig.defaultLogoAssetName

    @State private var selectedSection: SettingsSection = .accountAndPlan
    @State private var showSignInSheet = false
    @State private var showQuickGuide = false

    @State private var draftAddress: String
    @State private var health: ServerHealth?
    @State private var isCheckingServer = false

    init(
        currentAddress: String,
        onSave: @escaping (String) -> Void,
        onReload: @escaping () -> Void,
        onReplayWelcome: (() -> Void)? = nil
    ) {
        self.currentAddress = currentAddress
        self.onSave = onSave
        self.onReload = onReload
        self.onReplayWelcome = onReplayWelcome
        _draftAddress = State(initialValue: currentAddress)
    }

    private var isCompact: Bool {
        horizontalSizeClass == .compact
    }

    var body: some View {
        Group {
            if isCompact {
                iPhoneSettingsStack
            } else {
                iPadSettingsSplit
            }
        }
        .tint(SkyTheme.blue600)
        .task {
            if auth.session == nil {
                await auth.start()
            }
            if billing.products.isEmpty {
                await billing.loadProducts()
            }
        }
        .sheet(isPresented: $showSignInSheet) {
            SignInSheetView(
                isModalCard: false,
                onClose: { showSignInSheet = false },
                onContinue: { showSignInSheet = false }
            )
            #if os(iOS)
            .presentationDetents([.large])
            .presentationCornerRadius(28)
            #endif
        }
        .sheet(isPresented: $showQuickGuide) {
            QuickGuideSheetView()
        }
    }

    // MARK: - iPad Split View

    private var iPadSettingsSplit: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Done")
                            .font(.system(size: 15.5, weight: .semibold))
                    }
                    .foregroundStyle(SkyTheme.blue600)
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 18)
                .padding(.top, 12)

                Text("Settings")
                    .font(.system(size: 32, weight: .black, design: .rounded))
                    .foregroundStyle(SkyTheme.navy900)
                    .padding(.horizontal, 18)
                    .padding(.top, 4)
                    .padding(.bottom, 18)

                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(SettingsSection.visibleCases) { section in
                            let isSelected = selectedSection == section
                            Button {
                                selectedSection = section
                            } label: {
                                HStack(spacing: 12) {
                                    IconTileBadge(
                                        systemName: section.iconName,
                                        foreground: .white,
                                        background: section.badgeColor,
                                        size: 30,
                                        cornerRadius: 8
                                    )
                                    Text(section.rawValue)
                                        .font(.system(size: 15, weight: isSelected ? .bold : .medium))
                                        .foregroundStyle(isSelected ? SkyTheme.blue600 : SkyTheme.navy900)
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .frame(height: 46)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(isSelected ? SkyTheme.sky100 : Color.clear)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                }

                Spacer()
            }
            .frame(width: 268)
            .background(SkyTheme.sky50.ignoresSafeArea())

            Rectangle()
                .fill(SkyTheme.line.opacity(0.75))
                .frame(width: 1)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(selectedSection.rawValue)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(SkyTheme.navy900)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)

                    detailContent(for: selectedSection)
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 16)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            .background(SkyTheme.sky25.ignoresSafeArea())
        }
    }

    // MARK: - iPhone NavigationStack

    private var iPhoneSettingsStack: some View {
        NavigationStack {
            List {
                ForEach(SettingsSection.visibleCases) { section in
                    NavigationLink {
                        ScrollView {
                            detailContent(for: section)
                                .padding(18)
                        }
                        .background(SkyTheme.sky25.ignoresSafeArea())
                        .navigationTitle(section.rawValue)
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { dismiss() }
                                    .fontWeight(.semibold)
                            }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            IconTileBadge(
                                systemName: section.iconName,
                                foreground: .white,
                                background: section.badgeColor,
                                size: 30,
                                cornerRadius: 8
                            )
                            Text(section.rawValue)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(SkyTheme.navy900)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Detail Panes

    @ViewBuilder
    private func detailContent(for section: SettingsSection) -> some View {
        switch section {
        case .accountAndPlan:
            accountAndPlanPane
        case .guide:
            guidePane
        case .server:
            serverPane
        case .about:
            aboutPane
        }
    }

    // MARK: - Account & Plan

    private var accountAndPlanPane: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                UserAvatarBadge(initial: accountInitial, size: 50)

                VStack(alignment: .leading, spacing: 3) {
                    Text(accountTitle)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(SkyTheme.navy900)
                        .lineLimit(1)
                    Text(accountStatusSubtitle)
                        .font(.system(size: 13.5))
                        .foregroundStyle(SkyTheme.slate600)
                }

                Spacer(minLength: 8)

                if billing.isPro {
                    ProPillBadge()
                } else if auth.isGuest {
                    Button {
                        showSignInSheet = true
                    } label: {
                        Text("Sign in")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .frame(minHeight: 40)
                            .background(SkyTheme.blue600, in: Capsule())
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(18)
            .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(SkyTheme.line.opacity(0.85), lineWidth: 1)
            )

            groupedSection(title: "Plan", footer: "Changes and cancellations happen in your App Store account.") {
                HStack {
                    Text(billing.isPro ? "MusicScan Pro" : "Free plan")
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(SkyTheme.navy900)
                    Spacer()
                    Text(planTrailingLabel)
                        .font(.system(size: 14))
                        .foregroundStyle(SkyTheme.slate600)
                }
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)

                Divider().padding(.leading, 18)

                if billing.isPro {
                    Button {
                        Task { await billing.openManageSubscriptions() }
                    } label: {
                        HStack {
                            Text("Manage subscription")
                                .font(.system(size: 15.5, weight: .medium))
                                .foregroundStyle(SkyTheme.blue600)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(SkyTheme.slate600)
                        }
                        .padding(.horizontal, 18)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        Task {
                            _ = await billing.presentPaywall(
                                placement: AppConfig.superwallUnlockPlacement,
                                reason: "Unlock full pages, edit and fix flagged bars, play back with sampled instruments, and export."
                            )
                        }
                    } label: {
                        HStack {
                            Text("Upgrade to MusicScan Pro")
                                .font(.system(size: 15.5, weight: .semibold))
                                .foregroundStyle(SkyTheme.blue600)
                            Spacer()
                            Text(billing.yearlyProduct?.displayPrice.appending("/yr") ?? "$99.99/yr")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(SkyTheme.navy900)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(SkyTheme.marigold, in: Capsule())
                        }
                        .padding(.horizontal, 18)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Divider().padding(.leading, 18)

                Button {
                    Task { _ = await billing.restorePurchases() }
                } label: {
                    HStack {
                        Text(billing.isRestoring ? "Restoring purchases…" : "Restore purchases")
                            .font(.system(size: 15.5, weight: .medium))
                            .foregroundStyle(SkyTheme.blue600)
                        Spacer()
                        if billing.isRestoring {
                            ProgressView()
                        }
                    }
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(billing.isRestoring || billing.isPurchasing)
            }

            if let error = billing.lastError {
                statusBanner(text: error, isError: true)
            } else if let status = billing.statusMessage {
                statusBanner(text: status, isError: false)
            }

            groupedSection(title: "Account", footer: nil) {
                if auth.isGuest {
                    Button {
                        showSignInSheet = true
                    } label: {
                        HStack {
                            Text("Sign in with Apple, Google, or email")
                                .font(.system(size: 15.5, weight: .medium))
                                .foregroundStyle(SkyTheme.blue600)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(SkyTheme.slate600)
                        }
                        .padding(.horizontal, 18)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        Task { await auth.signOut() }
                    } label: {
                        HStack {
                            Text("Sign out")
                                .font(.system(size: 15.5, weight: .medium))
                                .foregroundStyle(SkyTheme.wrongInk)
                            Spacer()
                            if auth.isBusy {
                                ProgressView()
                            }
                        }
                        .padding(.horizontal, 18)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(auth.isBusy)
                }
            }

            if let error = auth.lastError {
                statusBanner(text: error, isError: true)
            } else if let status = auth.statusMessage {
                statusBanner(text: status, isError: false)
            }

            testingAndSLISection
        }
    }

    // MARK: - Testing & Scan SLI Telemetry

    private var testingAndSLISection: some View {
        VStack(alignment: .leading, spacing: 20) {
            groupedSection(
                title: "Testing & Paywall Bypass",
                footer: "When Bypass Paywall is on, the editor never blocks playback, editing, Fix It, or export. Use 'Reset Free Guest Quota' to create a fresh guest session on the server so your next scan returns a full free page."
            ) {
                Toggle(isOn: $billing.bypassPaywallForTesting) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bypass Paywall (Test Mode)")
                            .font(.system(size: 15.5, weight: .semibold))
                            .foregroundStyle(SkyTheme.navy900)
                        Text(billing.bypassPaywallForTesting ? "All editor features unlocked for testing" : "Showing preview blur veil & paywall")
                            .font(.system(size: 12.5))
                            .foregroundStyle(SkyTheme.slate600)
                    }
                }
                .padding(.horizontal, 18)
                .frame(minHeight: 58)

                Divider().padding(.leading, 18)

                Button {
                    Task {
                        await auth.signOut()
                        onReload()
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Reset Free Guest Quota")
                                .font(.system(size: 15.5, weight: .medium))
                                .foregroundStyle(SkyTheme.blue600)
                            Text("Rotates anonymous guest ID for a fresh full-page server allowance")
                                .font(.system(size: 12.5))
                                .foregroundStyle(SkyTheme.slate600)
                        }
                        Spacer()
                        if auth.isBusy {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(SkyTheme.blue600)
                        }
                    }
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(auth.isBusy)

                Divider().padding(.leading, 18)

                HStack(spacing: 12) {
                    MusicScanLogoView(size: 36, showShadow: false)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("App Logo Asset")
                            .font(.system(size: 15.5, weight: .semibold))
                            .foregroundStyle(SkyTheme.navy900)
                        Text("Or set AppConfig.defaultLogoAssetName in AppConfig.swift")
                            .font(.system(size: 12))
                            .foregroundStyle(SkyTheme.slate600)
                    }

                    Spacer()

                    Picker("Logo", selection: $selectedLogoAsset) {
                        Text("BrandLogo (512×512)").tag("BrandLogo")
                        Text("HeroScan (1600×900)").tag("HeroScan")
                        Text("FeatureFixIt (800×600)").tag("FeatureFixIt")
                        Text("EmptyDropzone (800×600)").tag("EmptyDropzone")
                        Text("Sky Vector").tag("vector")
                    }
                    .pickerStyle(.menu)
                }
                .padding(.horizontal, 18)
                .frame(minHeight: 58)
            }

            groupedSection(
                title: "Scan Latency SLI",
                footer: "Tracks on-device photo orientation/prep time (ms), Modal GPU OMR inference time (s), and end-to-end wall-clock duration per page."
            ) {
                if let latest = sliRecorder.latest {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Last Scan E2E", systemImage: "timer")
                                .font(.system(size: 14.5, weight: .semibold))
                                .foregroundStyle(SkyTheme.navy900)
                            Spacer()
                            Text(String(format: "%.2f s", latest.pageWallSeconds))
                                .font(.system(size: 15, weight: .bold, design: .monospaced))
                                .foregroundStyle(SkyTheme.blue600)
                        }

                        HStack(spacing: 14) {
                            sliMetricPill(
                                label: "On-Device Prep",
                                value: "\(latest.onDevicePrepMs) ms"
                            )
                            sliMetricPill(
                                label: "Modal GPU OMR",
                                value: latest.serverOmrSeconds.map { String(format: "%.2f s", $0) } ?? "—"
                            )
                            sliMetricPill(
                                label: "p50 / p95",
                                value: String(
                                    format: "%.1fs / %.1fs",
                                    sliRecorder.p50WallSeconds ?? latest.pageWallSeconds,
                                    sliRecorder.p95WallSeconds ?? latest.pageWallSeconds
                                )
                            )
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)

                    ForEach(Array(sliRecorder.entries.prefix(6))) { entry in
                        Divider().padding(.leading, 18)
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(entry.title) · Page \(entry.pageNumber)")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(SkyTheme.navy900)
                                    .lineLimit(1)
                                Text("\(entry.measuresCount) bars · \(entry.fastMode ? "Fast 2m" : "Full 28m") · prep \(entry.onDevicePrepMs)ms\(entry.serverOmrSeconds.map { String(format: " · GPU %.1fs", $0) } ?? "")")
                                    .font(.system(size: 12))
                                    .foregroundStyle(SkyTheme.slate600)
                            }
                            Spacer()
                            Text(String(format: "%.1fs", entry.pageWallSeconds))
                                .font(.system(size: 13.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(SkyTheme.navy900)
                        }
                        .padding(.horizontal, 18)
                        .frame(minHeight: 48)
                    }

                    Divider().padding(.leading, 18)

                    Button {
                        sliRecorder.clear()
                    } label: {
                        HStack {
                            Text("Clear SLI History (\(sliRecorder.entries.count))")
                                .font(.system(size: 14.5, weight: .medium))
                                .foregroundStyle(SkyTheme.wrongInk)
                            Spacer()
                        }
                        .padding(.horizontal, 18)
                        .frame(minHeight: 46)
                    }
                    .buttonStyle(.plain)
                } else {
                    HStack {
                        Text("No scans recorded in this session yet.")
                            .font(.system(size: 14.5))
                            .foregroundStyle(SkyTheme.slate600)
                        Spacer()
                    }
                    .padding(.horizontal, 18)
                    .frame(minHeight: 52)
                }
            }
        }
    }

    private func sliMetricPill(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SkyTheme.slate600)
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(SkyTheme.navy900)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SkyTheme.sky50, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Guide & Shortcuts

    private var guidePane: some View {
        VStack(alignment: .leading, spacing: 20) {
            groupedSection(title: "Editing & Practice", footer: "Full MuseScore / Dorico keyboard shortcuts, Apple Pencil double-tap, and iPad touch tips.") {
                Button {
                    showQuickGuide = true
                } label: {
                    HStack {
                        Text("Quick Guide & Keyboard Shortcuts")
                            .font(.system(size: 15.5, weight: .medium))
                            .foregroundStyle(SkyTheme.blue600)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(SkyTheme.slate600)
                    }
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if let onReplayWelcome {
                    Divider().padding(.leading, 18)
                    Button {
                        dismiss()
                        onReplayWelcome()
                    } label: {
                        HStack {
                            Text("Show Welcome Screen")
                                .font(.system(size: 15.5, weight: .medium))
                                .foregroundStyle(SkyTheme.blue600)
                            Spacer()
                            Image(systemName: "sparkles")
                                .foregroundStyle(SkyTheme.blue600)
                        }
                        .padding(.horizontal, 18)
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Reading Server

    private var serverPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            groupedSection(
                title: "MusicScan Reading Server",
                footer: "Sheet music OCR runs on the hosted GPU server by default, or you can point to a local Mac server (`HOST=0.0.0.0 scripts/run.sh`)."
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    TextField("https://…", text: $draftAddress, axis: .vertical)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .lineLimit(1...3)
                        .font(.system(.footnote, design: .monospaced))
                        .padding(12)
                        .background(SkyTheme.sky25, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(SkyTheme.line, lineWidth: 1))
                        .onChange(of: draftAddress) { _, _ in
                            health = nil
                        }

                    HStack(spacing: 10) {
                        Button {
                            Task { await runHealthCheck() }
                        } label: {
                            HStack(spacing: 6) {
                                if isCheckingServer {
                                    ProgressView().controlSize(.small)
                                }
                                Text(isCheckingServer ? "Checking…" : "Test connection")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isCheckingServer || ServerConfig.normalizedURL(from: draftAddress) == nil)

                        Button("Save & Reload") {
                            if let normalized = ServerConfig.normalizedURL(from: draftAddress) {
                                onSave(normalized.absoluteString)
                                onReload()
                                dismiss()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(ServerConfig.normalizedURL(from: draftAddress) == nil)
                    }

                    if let health {
                        Label(
                            health.message,
                            systemImage: health.state == .connected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(health.state == .connected ? SkyTheme.sureInk : SkyTheme.wrongInk)
                    }
                }
                .padding(18)

                Divider().padding(.leading, 18)

                Button {
                    onReload()
                    dismiss()
                } label: {
                    HStack {
                        Text("Reload Workspace")
                            .font(.system(size: 15.5, weight: .medium))
                            .foregroundStyle(SkyTheme.blue600)
                        Spacer()
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(SkyTheme.blue600)
                    }
                    .padding(.horizontal, 18)
                    .frame(minHeight: 50)
                }
                .buttonStyle(.plain)

                if currentAddress != AppConfig.defaultServerAddress {
                    Divider().padding(.leading, 18)
                    Button {
                        draftAddress = AppConfig.defaultServerAddress
                        onSave(AppConfig.defaultServerAddress)
                        onReload()
                    } label: {
                        HStack {
                            Text("Reset to Hosted Server")
                                .font(.system(size: 15.5, weight: .medium))
                                .foregroundStyle(SkyTheme.blue600)
                            Spacer()
                        }
                        .padding(.horizontal, 18)
                        .frame(minHeight: 50)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - About

    private var aboutPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            groupedSection(
                title: "About MusicScan",
                footer: "OMR by copisteria © KobiMusic (Apache-2.0) · Engraving by VexFlow."
            ) {
                HStack {
                    Text("Version")
                        .font(.system(size: 15.5))
                        .foregroundStyle(SkyTheme.navy900)
                    Spacer()
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                        .font(.system(size: 15))
                        .foregroundStyle(SkyTheme.slate600)
                }
                .padding(.horizontal, 18)
                .frame(minHeight: 50)

                Divider().padding(.leading, 18)

                Link(destination: AppConfig.termsURL) {
                    HStack {
                        Text("Terms of Use")
                            .font(.system(size: 15.5))
                            .foregroundStyle(SkyTheme.blue600)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(SkyTheme.slate600)
                    }
                    .padding(.horizontal, 18)
                    .frame(minHeight: 50)
                }

                Divider().padding(.leading, 18)

                Link(destination: AppConfig.privacyURL) {
                    HStack {
                        Text("Privacy Policy")
                            .font(.system(size: 15.5))
                            .foregroundStyle(SkyTheme.blue600)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(SkyTheme.slate600)
                    }
                    .padding(.horizontal, 18)
                    .frame(minHeight: 50)
                }
            }
        }
    }

    // MARK: - Helpers

    private var accountTitle: String {
        guard let session = auth.session else {
            return "Guest account"
        }
        return session.displayLabel
    }

    private var accountInitial: String {
        if let email = auth.session?.email, let first = email.first {
            return String(first).uppercased()
        }
        return auth.isGuest ? "G" : "M"
    }

    private var accountStatusSubtitle: String {
        guard let session = auth.session else {
            return "Setting up guest session…"
        }
        if session.isAnonymous {
            return "Private on this device · link an account to sync"
        }
        if let provider = session.provider, !provider.isEmpty {
            return "Signed in with \(provider.capitalized)"
        }
        return "Signed in · syncing enabled"
    }

    private var planTrailingLabel: String {
        if billing.isPro {
            let tierName = billing.entitlement.productID == AppConfig.ProductID.monthly ? "Monthly" : "Yearly"
            if let periodEnd = billing.entitlement.periodEnd, !periodEnd.isEmpty {
                return "\(tierName) · renews \(periodEnd.prefix(10))"
            }
            return "\(tierName) · up to \(AppConfig.proPagesPerMonth) pages/mo"
        }
        return "1 full free page included"
    }

    private func statusBanner(text: String, isError: Bool) -> some View {
        Label(text, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .font(.footnote)
            .foregroundStyle(isError ? SkyTheme.wrongInk : SkyTheme.sureInk)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isError ? SkyTheme.wrongFill : SkyTheme.sureFill, in: RoundedRectangle(cornerRadius: 12))
    }

    private func groupedSection<Content: View>(
        title: String,
        footer: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(SkyTheme.slate600)
                .padding(.leading, 12)

            VStack(spacing: 0) {
                content()
            }
            .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(SkyTheme.line.opacity(0.85), lineWidth: 1)
            )

            if let footer {
                Text(footer)
                    .font(.system(size: 12.5))
                    .foregroundStyle(SkyTheme.slate600)
                    .padding(.leading, 12)
            }
        }
    }

    @MainActor
    private func runHealthCheck() async {
        isCheckingServer = true
        defer { isCheckingServer = false }
        health = await ServerHealth.check(address: draftAddress)
    }
}

#Preview("Settings") {
    SettingsSheetView(
        currentAddress: ServerConfig.hostedDefaultAddress,
        onSave: { _ in },
        onReload: {}
    )
}
