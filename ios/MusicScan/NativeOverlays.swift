import SwiftUI

/// Primary 2-tab navigation for MusicScan:
/// - `scan`: Effortless scanning with camera, photo library, PDF/MusicXML upload, and quick samples.
/// - `review`: Reviewing saved scans (`Your music`) and editing, fixing, playing, and exporting scores.
enum AppTab: String, CaseIterable, Identifiable, Sendable {
    case scan
    case review

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scan: return "Home"
        case .review: return "Review & Edit"
        }
    }

    var shortTitle: String {
        switch self {
        case .scan: return "Home"
        case .review: return "Review"
        }
    }

    var systemImage: String {
        switch self {
        case .scan: return "house.fill"
        case .review: return "music.note.list"
        }
    }
}

// MARK: - Bottom 2-Tab Bar (iPhone Duo, iPhone & iPad Safe)

/// Clean, unmistakable 2-tab bottom navigation bar (`Scan` | `Review & Edit`).
/// Placed below the active workspace (not floating over the WebView) so it never covers
/// the score canvas, piano input pad, or practice bar on compact screens like iPhone Duo.
struct MusicScanTabBar: View {
    @Binding var selectedTab: AppTab
    let stage: WorkspaceStage
    let libraryCount: Int

    var body: some View {
        GeometryReader { geo in
            let isUltraNarrow = geo.size.width < 340
            HStack(spacing: 8) {
                tabButton(for: .scan, compact: isUltraNarrow)
                tabButton(for: .review, compact: isUltraNarrow)
            }
            .padding(5)
            .modifier(AdaptiveTabBarSurfaceModifier())
            .frame(maxWidth: min(geo.size.width - 24, 460))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 62)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .background(
            SkyTheme.sky25
                .opacity(0.96)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(SkyTheme.line.opacity(0.7))
                        .frame(height: 0.75)
                }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func tabButton(for tab: AppTab, compact: Bool) -> some View {
        let isSelected = selectedTab == tab
        let label = compact ? tab.shortTitle : tab.title
        let iconName: String = {
            if tab == .review && stage == .editor {
                return "pencil.and.outline"
            }
            return tab.systemImage
        }()

        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                selectedTab = tab
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: iconName)
                    .font(.system(size: compact ? 15 : 16, weight: .semibold))

                Text(label)
                    .font(.system(size: compact ? 13.5 : 14.5, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                if tab == .review {
                    reviewStatusBadge(isSelected: isSelected)
                }
            }
            .foregroundStyle(isSelected ? .white : SkyTheme.navy900)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .padding(.horizontal, 10)
            .background(
                Capsule()
                    .fill(isSelected ? SkyTheme.blue600 : Color.clear)
                    .shadow(
                        color: isSelected ? SkyTheme.blue600.opacity(0.26) : .clear,
                        radius: 8,
                        y: 3
                    )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private func reviewStatusBadge(isSelected: Bool) -> some View {
        if stage == .reading {
            ProgressView()
                .controlSize(.mini)
                .tint(isSelected ? .white : SkyTheme.blue600)
        } else if stage == .editor {
            Circle()
                .fill(isSelected ? SkyTheme.marigold : SkyTheme.blue600)
                .frame(width: 7, height: 7)
                .accessibilityLabel("Score open")
        } else if libraryCount > 0 {
            Text("\(libraryCount)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(isSelected ? SkyTheme.blue700 : SkyTheme.blue700)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.white.opacity(0.92) : SkyTheme.sky100)
                )
        }
    }
}

// MARK: - Shared Workspace Header & Preparing Overlay (Zero Tab-Switch Header Jump)

/// Shared header bar used identically across Scan, Review & Edit, and Skeleton Loading states
/// so top-right action buttons stay pixel-locked when switching tabs and meet 44pt touch guidelines.
struct SkyWorkspaceHeader: View {
    let title: String
    let isPro: Bool
    let compact: Bool
    let scale: CGFloat
    let onOpenGuide: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            MusicScanLogoView(size: (compact ? 34 : 38) * min(scale, 1.1), showShadow: false)

            HStack(spacing: 7) {
                Text(title)
                    .font(.system(size: (compact ? 19 : 21) * min(scale, 1.1), weight: .black, design: .rounded))
                    .foregroundStyle(SkyTheme.navy900)
                    .lineLimit(1)

                if isPro {
                    ProPillBadge()
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                Button(action: onOpenGuide) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(SkyTheme.blue700)
                        .frame(width: 42, height: 42)
                        .background(.white.opacity(0.94), in: Circle())
                        .overlay(Circle().stroke(SkyTheme.line, lineWidth: 1))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Quick Guide and Shortcuts")

                Button(action: onOpenSettings) {
                    Image(systemName: isPro ? "crown.fill" : "person.crop.circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(isPro ? SkyTheme.marigold : SkyTheme.navy900)
                        .frame(width: 42, height: 42)
                        .background(.white.opacity(0.94), in: Circle())
                        .overlay(Circle().stroke(SkyTheme.line, lineWidth: 1))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Account, Plan and Settings")
            }
        }
    }
}

/// Immediate tactile progress card shown between dismissing a native camera/photo/file picker
/// and the live score reader taking over, eliminating any silent dead-zone.
struct PreparingImportOverlayView: View {
    let message: String
    let progress: Double?

    var body: some View {
        ZStack {
            SkyTheme.navy900.opacity(0.22)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(SkyTheme.sky50)
                            .frame(width: 42, height: 42)
                        ProgressView()
                            .tint(SkyTheme.blue600)
                    }

                    Text(message)
                        .font(.system(size: 15.5, weight: .bold, design: .rounded))
                        .foregroundStyle(SkyTheme.navy900)
                        .lineLimit(2)

                    Spacer(minLength: 4)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(SkyTheme.sky100)
                        Capsule()
                            .fill(SkyTheme.heroGradient)
                            .frame(width: max(18, geo.size.width * min(max(progress ?? 0.35, 0.08), 1.0)))
                            .animation(.easeOut(duration: 0.25), value: progress)
                    }
                }
                .frame(height: 6)
            }
            .padding(18)
            .frame(maxWidth: 340)
            .engravedCard(cornerRadius: 22)
            .padding(.horizontal, 24)
        }
    }
}

// MARK: - Tab 1: Dedicated Scan & Upload Workspace

/// Effortless native SwiftUI scanning & upload hub tailored for iPhone Duo (Outer & Inner),
/// iPhone, and iPad. Every action routes directly into the real MusicScan transcription engine.
struct ScanWorkspaceView: View {
    let isPro: Bool
    let isServerLoading: Bool
    let loadError: String?
    let stage: WorkspaceStage
    let activeTitle: String
    let fastMode: Bool
    let samples: [WebSampleItem]
    let onScanCamera: () -> Void
    let onChoosePhotos: () -> Void
    let onUploadFile: () -> Void
    let onToggleFastMode: (Bool) -> Void
    let onOpenSample: (Int) -> Void
    let onResumeEditing: () -> Void
    let onOpenGuide: () -> Void
    let onOpenSettings: () -> Void
    let onRetryConnection: () -> Void

    /// Samples are hidden on the main Scan screen for now to keep it focused on Scan, Upload, and Photos.
    private let showSamples = false

    private var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let scale = min(max(width / 390.0, 0.90), 1.24)
            let isShort = height < 660
            let horizontalPad: CGFloat = width < 380 ? 18 : (width < 600 ? 24 : 36)
            let contentMaxWidth: CGFloat = width >= 720 ? 640 : 540
            let sectionGap: CGFloat = (isShort ? 14 : 20) * min(scale, 1.12)

            ZStack {
                SkyDitheredCanvas()
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        SkyWorkspaceHeader(
                            title: "MusicScan",
                            isPro: isPro,
                            compact: width < 380,
                            scale: scale,
                            onOpenGuide: onOpenGuide,
                            onOpenSettings: onOpenSettings
                        )

                        Spacer(minLength: max(22, height * 0.055))

                        VStack(alignment: .leading, spacing: sectionGap) {
                            heroSection(scale: scale, isShort: isShort)

                            primaryActionsSection(scale: scale, height: height)

                            fastModeRow(scale: scale)

                            if showSamples && !samples.isEmpty {
                                samplesSection(width: width)
                            }
                        }

                        Spacer(minLength: max(28, height * 0.07))

                        simpleTipsList(scale: scale)
                    }
                    .padding(.horizontal, horizontalPad)
                    .padding(.top, isShort ? 10 : 18)
                    .padding(.bottom, max(22, height * 0.04) + (stage == .editor || stage == .reading || loadError != nil ? 64 : 0))
                    .frame(maxWidth: contentMaxWidth, minHeight: height, alignment: .topLeading)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            // Non-shifting top hairline progress bar during initial warm-up (zero layout jump)
            .overlay(alignment: .top) {
                if isServerLoading && loadError == nil {
                    SkyTopProgressBar()
                        .transition(.opacity)
                }
            }
            // Non-shifting bottom status card when a score is open/reading or offline
            .overlay(alignment: .bottom) {
                if let loadError {
                    offlineBanner(message: loadError)
                        .padding(.horizontal, horizontalPad)
                        .padding(.bottom, 10)
                        .frame(maxWidth: contentMaxWidth)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if stage == .editor || stage == .reading {
                    activeWorkspaceBanner
                        .padding(.horizontal, horizontalPad)
                        .padding(.bottom, 10)
                        .frame(maxWidth: contentMaxWidth)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.24), value: isServerLoading)
            .animation(.spring(response: 0.3, dampingFraction: 0.86), value: stage)
            .animation(.easeOut(duration: 0.24), value: loadError)
        }
    }

    // MARK: Status & Quick-Return Banners

    private var activeWorkspaceBanner: some View {
        Button(action: onResumeEditing) {
            HStack(spacing: 12) {
                if stage == .reading {
                    ProgressView()
                        .tint(SkyTheme.blue600)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(SkyTheme.blue600, in: Circle())
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(stage == .reading ? "Reading your score…" : "Score open in Review & Edit")
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(SkyTheme.navy900)
                    Text(activeTitle.isEmpty ? "Tap to return to the editor" : activeTitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(SkyTheme.slate600)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(SkyTheme.blue600)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(SkyTheme.sky50, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(SkyTheme.sky200, lineWidth: 1.2)
            )
        }
        .buttonStyle(.plain)
    }

    private var connectingPill: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(SkyTheme.blue600)
            Text("Connecting to MusicScan score reader…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SkyTheme.slate600)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.white.opacity(0.9), in: Capsule())
        .overlay(Capsule().stroke(SkyTheme.line, lineWidth: 1))
    }

    private func offlineBanner(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(SkyTheme.wrongInk)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SkyTheme.wrongInk)
                .lineLimit(2)
            Spacer(minLength: 6)
            Button("Retry", action: onRetryConnection)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(SkyTheme.blue600)
        }
        .padding(12)
        .background(SkyTheme.wrongFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Hero & Proportional Screen-Scaling Actions

    private func heroSection(scale: CGFloat, isShort: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            Text("Scan a page. \(Text("Play it.").foregroundStyle(SkyTheme.blue600))")
                .font(.system(size: (isShort ? 28 : 34) * scale, weight: .black, design: .rounded))
                .foregroundStyle(SkyTheme.navy900)
                .fixedSize(horizontal: false, vertical: true)

            Text("Scan printed pages or PDFs into playable, editable scores.")
                .font(.system(size: (isShort ? 14.5 : 15.5) * min(scale, 1.1)))
                .foregroundStyle(SkyTheme.slate600)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func primaryActionsSection(scale: CGFloat, height: CGFloat) -> some View {
        let heroHeight = min(max(height * 0.145, 92 * scale), 132)
        let secondaryHeight = min(max(height * 0.115, 76 * scale), 108)
        let cardGap = 12 * scale

        return VStack(spacing: cardGap) {
            scanHeroButton(scale: scale, minHeight: heroHeight)

            HStack(spacing: cardGap) {
                scaledSecondaryButton(
                    icon: "doc.badge.plus",
                    title: "Upload",
                    subtitle: "PDF or MusicXML",
                    scale: scale,
                    minHeight: secondaryHeight,
                    action: onUploadFile
                )

                scaledSecondaryButton(
                    icon: "photo.on.rectangle.angled",
                    title: "Choose Photos",
                    subtitle: "Photo library",
                    scale: scale,
                    minHeight: secondaryHeight,
                    action: onChoosePhotos
                )
            }
        }
    }

    private func scanHeroButton(scale: CGFloat, minHeight: CGFloat) -> some View {
        let corner = 22 * min(scale, 1.12)
        return Button(action: onScanCamera) {
            HStack(spacing: 14 * scale) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14 * scale, style: .continuous)
                        .fill(Color.white.opacity(0.20))
                        .frame(width: 50 * scale, height: 50 * scale)
                    Image(systemName: isSimulator ? "photo.stack.fill" : "doc.viewfinder.fill")
                        .font(.system(size: 24 * scale, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(isSimulator ? "Scan Sheet Music" : "Scan Pages")
                        .font(.system(size: 20 * scale, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.86)

                    Text(isSimulator
                         ? "Pick sheet music pages to transcribe"
                         : "Live edge crop · manual shutter")
                        .font(.system(size: 13.5 * min(scale, 1.04), weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.90))
                        .lineLimit(1)
                        .minimumScaleFactor(0.84)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 26 * min(scale, 1.12)))
                    .foregroundStyle(.white.opacity(0.94))
                    .fixedSize()
            }
            .padding(.horizontal, 18 * scale)
            .padding(.vertical, 16 * scale)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(SkyTheme.heroGradient)

                    StippledHalftoneWash(
                        tint: .white,
                        maxOpacity: 0.30,
                        dotSpacing: 5.5,
                        maxDotRadius: 1.4,
                        origin: .topTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.36), Color.white.opacity(0.06)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: SkyTheme.blue600.opacity(0.28), radius: 18, y: 8)
        }
        .buttonStyle(TactileCardButtonStyle())
        .disabled(loadError != nil)
        .opacity(loadError != nil ? 0.65 : 1)
    }

    private func scaledSecondaryButton(
        icon: String,
        title: String,
        subtitle: String,
        scale: CGFloat,
        minHeight: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        let corner = 18 * min(scale, 1.12)
        return Button(action: action) {
            VStack(alignment: .leading, spacing: 8 * min(scale, 1.1)) {
                HStack {
                    IconTileBadge(
                        systemName: icon,
                        foreground: SkyTheme.blue600,
                        background: SkyTheme.sky50,
                        size: 38 * min(scale, 1.12),
                        cornerRadius: 11
                    )
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12 * min(scale, 1.1), weight: .semibold))
                        .foregroundStyle(SkyTheme.slate600.opacity(0.75))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15.5 * min(scale, 1.12), weight: .bold, design: .rounded))
                        .foregroundStyle(SkyTheme.navy900)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(subtitle)
                        .font(.system(size: 12 * min(scale, 1.08)))
                        .foregroundStyle(SkyTheme.slate600)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .padding(.horizontal, 14 * scale)
            .padding(.vertical, 13 * scale)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            .engravedCard(cornerRadius: corner)
        }
        .buttonStyle(TactileCardButtonStyle())
        .disabled(loadError != nil)
        .opacity(loadError != nil ? 0.65 : 1)
    }

    // MARK: Fast Mode Toggle

    private func fastModeRow(scale: CGFloat) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 14 * min(scale, 1.1), weight: .bold))
                .foregroundStyle(fastMode ? .white : SkyTheme.blue600)
                .frame(width: 32 * min(scale, 1.08), height: 32 * min(scale, 1.08))
                .background(
                    fastMode ? SkyTheme.blue600 : SkyTheme.sky50,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .animation(.easeInOut(duration: 0.18), value: fastMode)

            VStack(alignment: .leading, spacing: 2) {
                Text("Fast mode")
                    .font(.system(size: 14.5 * min(scale, 1.08), weight: .bold))
                    .foregroundStyle(SkyTheme.navy900)
                Text("Smaller model · ~4× quicker reading")
                    .font(.system(size: 12 * min(scale, 1.06)))
                    .foregroundStyle(SkyTheme.slate600)
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            Toggle("", isOn: Binding(
                get: { fastMode },
                set: { onToggleFastMode($0) }
            ))
            .labelsHidden()
            .fixedSize()
            .tint(SkyTheme.blue600)
        }
        .padding(.horizontal, 14 * scale)
        .padding(.vertical, 10 * min(scale, 1.1))
        .engravedCard(cornerRadius: 16 * min(scale, 1.1))
    }

    // MARK: Real Server Sample Scores

    private func samplesSection(width: CGFloat) -> some View {
        let columns: [GridItem] = {
            let count = width >= 620 ? 4 : (width >= 440 ? 3 : 2)
            return Array(repeating: GridItem(.flexible(), spacing: 10), count: count)
        }()

        return VStack(alignment: .leading, spacing: 10) {
            Text("No sheet music handy? Try a sample")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(SkyTheme.navy900)

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(samples) { sample in
                    Button {
                        onOpenSample(sample.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Group {
                                if let thumbURL = URL(string: sample.thumbURL) {
                                    AsyncImage(url: thumbURL) { phase in
                                        switch phase {
                                        case .success(let image):
                                            image
                                                .resizable()
                                                .scaledToFill()
                                        default:
                                            samplePlaceholder
                                        }
                                    }
                                } else {
                                    samplePlaceholder
                                }
                            }
                            .frame(height: 76)
                            .frame(maxWidth: .infinity)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(SkyTheme.line.opacity(0.65), lineWidth: 0.75)
                            )

                            Text(sample.title.isEmpty ? "Sample Score" : sample.title)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(SkyTheme.navy900)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .engravedCard(cornerRadius: 15)
                    }
                    .buttonStyle(TactileCardButtonStyle(pressedScale: 0.965))
                }
            }
        }
    }

    private var samplePlaceholder: some View {
        ZStack {
            SkyTheme.sky50
            Image(systemName: "music.note.list")
                .font(.system(size: 20))
                .foregroundStyle(SkyTheme.blue600.opacity(0.55))
        }
    }

    // MARK: Simple Todo-Style Tips List

    private var scanTips: [(title: String, detail: String)] {
        [
            ("Flat in frame", "sideways photos auto-rotate"),
            ("Even light", "avoid shadows across staves"),
            ("Sharp focus", "keep staff lines crisp"),
            ("Pen marks OK", "colored ink is stripped")
        ]
    }

    private func simpleTipsList(scale: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 7 * min(scale, 1.08)) {
            Text("TIPS")
                .font(.system(size: 11 * min(scale, 1.08), weight: .bold, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(SkyTheme.slate600.opacity(0.85))
                .padding(.bottom, 1)

            ForEach(Array(scanTips.enumerated()), id: \.offset) { _, tip in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11 * min(scale, 1.08), weight: .bold))
                        .foregroundStyle(SkyTheme.sureInk)
                        .frame(width: 14, alignment: .center)

                    (
                        Text(tip.title)
                            .font(.system(size: 13 * min(scale, 1.08), weight: .semibold))
                            .foregroundStyle(SkyTheme.navy900)
                        + Text(" — \(tip.detail)")
                            .font(.system(size: 13 * min(scale, 1.08)))
                            .foregroundStyle(SkyTheme.slate600)
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Tab 2 Empty State (Before First Scan)

/// Shown in the Review & Edit tab when the user has not scanned or opened a score yet.
struct ReviewEmptyOverlayView: View {
    var isPro: Bool = false
    let hasSamples: Bool
    let onGoToScan: () -> Void
    let onTrySample: () -> Void
    let onOpenGuide: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let scale = min(max(width / 390.0, 0.90), 1.24)
            let isShort = height < 660
            let horizontalPad: CGFloat = width < 380 ? 18 : (width < 600 ? 24 : 36)
            let contentMaxWidth: CGFloat = width >= 720 ? 640 : 540

            ZStack {
                SkyDitheredCanvas()
                    .ignoresSafeArea()

                StaffLinesBackdrop(lineSpacing: 16)
                    .opacity(0.45)

                VStack(spacing: 0) {
                    SkyWorkspaceHeader(
                        title: "Review & Edit",
                        isPro: isPro,
                        compact: width < 380,
                        scale: scale,
                        onOpenGuide: onOpenGuide,
                        onOpenSettings: onOpenSettings
                    )
                    .padding(.horizontal, horizontalPad)
                    .padding(.top, isShort ? 10 : 18)
                    .frame(maxWidth: contentMaxWidth)

                    Spacer()

                    VStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(SkyTheme.sky50)
                                .frame(width: 72, height: 72)
                                .overlay(Circle().stroke(SkyTheme.sky200, lineWidth: 1))

                            Image(systemName: "music.note.list")
                                .font(.system(size: 30, weight: .semibold))
                                .foregroundStyle(SkyTheme.blue600)
                        }

                        VStack(spacing: 6) {
                            Text("No scores yet")
                                .font(.system(size: 22, weight: .black, design: .rounded))
                                .foregroundStyle(SkyTheme.navy900)
                                .multilineTextAlignment(.center)

                            Text("Scan sheet music or import a PDF or MusicXML to edit and play.")
                                .font(.system(size: 14.5))
                                .foregroundStyle(SkyTheme.slate600)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        VStack(spacing: 10) {
                            Button(action: onGoToScan) {
                                Label("Scan or Upload Music", systemImage: "doc.viewfinder")
                                    .font(.system(size: 15.5, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 48)
                                    .background(SkyTheme.heroGradient, in: Capsule())
                                    .shadow(color: SkyTheme.blue600.opacity(0.24), radius: 10, y: 4)
                            }
                            .buttonStyle(TactileCardButtonStyle())
                        }
                        .padding(.top, 4)
                    }
                    .padding(24)
                    .frame(maxWidth: 420)
                    .background {
                        ZStack {
                            RoundedRectangle(cornerRadius: 26, style: .continuous)
                                .fill(.white)
                            StippledHalftoneWash(
                                tint: SkyTheme.blue600,
                                maxOpacity: 0.08,
                                dotSpacing: 7.0,
                                maxDotRadius: 1.25,
                                origin: .topTrailing
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                        }
                        .shadow(color: SkyTheme.navy900.opacity(0.08), radius: 22, y: 10)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .stroke(SkyTheme.line, lineWidth: 1)
                    )
                    .padding(.horizontal, horizontalPad)

                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Skeleton Loading & Error Overlays

/// Shimmering Sky library skeleton shown while Review & Edit connects or hydrates saved scores,
/// using the exact same header metrics as Scan so tab switches never jump.
struct ConnectingOverlayView: View {
    let hostLabel: String
    var isPro: Bool = false
    var onOpenGuide: () -> Void = {}
    let onOpenSettings: () -> Void

    @State private var showSlowWakeHint = false
    @State private var elapsedSeconds = 0

    private var tuningStatusText: String {
        showSlowWakeHint ? "Connecting… \(elapsedSeconds)s" : "Loading scores…"
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let scale = min(max(width / 390.0, 0.90), 1.24)
            let isShort = height < 660
            let horizontalPad: CGFloat = width < 380 ? 18 : (width < 600 ? 24 : 36)
            let contentMaxWidth: CGFloat = width >= 720 ? 640 : 540
            let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: width >= 620 ? 3 : 2)

            ZStack {
                SkyDitheredCanvas()
                    .ignoresSafeArea()

                VStack(alignment: .leading, spacing: 0) {
                    SkyWorkspaceHeader(
                        title: "Review & Edit",
                        isPro: isPro,
                        compact: width < 380,
                        scale: scale,
                        onOpenGuide: onOpenGuide,
                        onOpenSettings: onOpenSettings
                    )

                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(SkyTheme.sky100)
                            .frame(width: 132, height: 22)
                            .skyShimmer()

                        Spacer()

                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(SkyTheme.blue600)
                            Text(tuningStatusText)
                                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                                .foregroundStyle(SkyTheme.slate600)
                                .contentTransition(.numericText())
                                .animation(.easeInOut(duration: 0.25), value: tuningStatusText)
                        }
                    }
                    .padding(.top, 26)
                    .padding(.bottom, 16)

                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(0..<4, id: \.self) { _ in
                            scoreSkeletonCard
                        }
                    }

                    if showSlowWakeHint {
                        VStack(spacing: 8) {
                            Text("Waking the score service — this only takes a few seconds.")
                                .font(.caption)
                                .foregroundStyle(SkyTheme.slate600)
                                .multilineTextAlignment(.center)

                            Button(action: onOpenSettings) {
                                Label("Account & Settings", systemImage: "slider.horizontal.3")
                                    .font(.footnote.weight(.semibold))
                            }
                            .modifier(AdaptiveGlassButtonModifier(prominent: false))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 22)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, horizontalPad)
                .padding(.top, isShort ? 10 : 18)
                .frame(maxWidth: contentMaxWidth, maxHeight: .infinity, alignment: .topLeading)
                .frame(maxWidth: .infinity)
            }
            .overlay(alignment: .top) {
                SkyTopProgressBar()
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                elapsedSeconds += 1
                if elapsedSeconds == 4 && !showSlowWakeHint {
                    withAnimation(.easeOut(duration: 0.3)) {
                        showSlowWakeHint = true
                    }
                }
            }
        }
    }

    private var scoreSkeletonCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(SkyTheme.sky50)
                VStack(spacing: 7) {
                    ForEach(0..<5, id: \.self) { _ in
                        Rectangle()
                            .fill(SkyTheme.sky200.opacity(0.65))
                            .frame(height: 1)
                    }
                }
                .padding(.horizontal, 14)
            }
            .frame(height: 98)
            .skyShimmer()

            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(SkyTheme.sky100)
                .frame(height: 14)
                .frame(maxWidth: 110)
                .skyShimmer()

            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(SkyTheme.sky50)
                .frame(height: 10)
                .frame(maxWidth: 74)
                .skyShimmer()
        }
        .padding(10)
        .engravedCard(cornerRadius: 18)
    }
}

/// Clean illustrated error card shown when the MusicScan server cannot be reached.
struct ConnectionErrorView: View {
    let message: String
    let hostLabel: String
    let onRetry: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        ZStack {
            SkyDitheredCanvas()
                .ignoresSafeArea()

            StaffLinesBackdrop(lineSpacing: 16)
                .opacity(0.55)

            ScrollView {
                VStack(spacing: 18) {
                    ZStack {
                        Circle()
                            .fill(SkyTheme.sky50)
                            .frame(width: 72, height: 72)
                            .overlay(
                                Circle()
                                    .stroke(SkyTheme.sky200, lineWidth: 1)
                            )

                        Image(systemName: "music.note.house")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(SkyTheme.blue600)
                    }

                    VStack(spacing: 8) {
                        Text("Can't Reach MusicScan")
                            .font(.system(size: 22, weight: .black, design: .rounded))
                            .foregroundStyle(SkyTheme.navy900)
                            .multilineTextAlignment(.center)

                        Text(message)
                            .font(.callout)
                            .foregroundStyle(SkyTheme.slate600)
                            .multilineTextAlignment(.center)
                    }

                    #if DEBUG
                    HStack(spacing: 6) {
                        Image(systemName: "server.rack")
                            .font(.caption)
                        Text(hostLabel)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(SkyTheme.blue700)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(SkyTheme.sky50, in: Capsule())
                    #endif

                    Text("The score reader may take a few seconds to wake up. Check your connection and tap Try Again.")
                        .font(.footnote)
                        .foregroundStyle(SkyTheme.slate600)
                        .multilineTextAlignment(.center)

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) {
                            Button("Settings", systemImage: "slider.horizontal.3", action: onOpenSettings)
                                .modifier(AdaptiveGlassButtonModifier(prominent: false))

                            Button("Try Again", systemImage: "arrow.clockwise", action: onRetry)
                                .modifier(AdaptiveGlassButtonModifier(prominent: true))
                        }

                        VStack(spacing: 10) {
                            Button("Try Again", systemImage: "arrow.clockwise", action: onRetry)
                                .modifier(AdaptiveGlassButtonModifier(prominent: true))
                            Button("Settings", systemImage: "slider.horizontal.3", action: onOpenSettings)
                                .modifier(AdaptiveGlassButtonModifier(prominent: false))
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(24)
                .frame(maxWidth: 440)
                .background(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(.white)
                        .shadow(color: SkyTheme.navy900.opacity(0.08), radius: 24, y: 12)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(SkyTheme.line, lineWidth: 1)
                )
                .padding(18)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

// MARK: - iOS 26 Liquid Glass with iOS 17–25 Sky Material Fallbacks

private struct AdaptiveTabBarSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(.white.opacity(0.95), in: Capsule())
                .overlay(Capsule().stroke(SkyTheme.line, lineWidth: 1))
                .shadow(color: SkyTheme.navy900.opacity(0.08), radius: 14, y: 4)
        }
    }
}

private struct AdaptiveGlassCapsuleModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(SkyTheme.line, lineWidth: 1))
                .shadow(color: SkyTheme.navy900.opacity(0.06), radius: 10, y: 4)
        }
    }
}

private struct AdaptiveGlassButtonModifier: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                content
                    .buttonStyle(.glassProminent)
                    .tint(SkyTheme.blue600)
            } else {
                content.buttonStyle(.glass)
            }
        } else {
            if prominent {
                content
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .tint(SkyTheme.blue600)
            } else {
                content
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(SkyTheme.navy900)
            }
        }
    }
}

#Preview("Scan Tab") {
    VStack(spacing: 0) {
        ScanWorkspaceView(
            isPro: false,
            isServerLoading: false,
            loadError: nil,
            stage: .home,
            activeTitle: "",
            fastMode: false,
            samples: [
                WebSampleItem(id: 0, title: "Mozart Sonata K. 545", thumbURL: ""),
                WebSampleItem(id: 1, title: "Chopin Prelude Op. 28", thumbURL: ""),
                WebSampleItem(id: 2, title: "Bach Minuet in G", thumbURL: ""),
                WebSampleItem(id: 3, title: "Debussy Arabesque", thumbURL: "")
            ],
            onScanCamera: {},
            onChoosePhotos: {},
            onUploadFile: {},
            onToggleFastMode: { _ in },
            onOpenSample: { _ in },
            onResumeEditing: {},
            onOpenGuide: {},
            onOpenSettings: {},
            onRetryConnection: {}
        )
        MusicScanTabBar(selectedTab: .constant(.scan), stage: .home, libraryCount: 2)
    }
}

#Preview("Review Empty") {
    VStack(spacing: 0) {
        ReviewEmptyOverlayView(
            hasSamples: true,
            onGoToScan: {},
            onTrySample: {},
            onOpenGuide: {},
            onOpenSettings: {}
        )
        MusicScanTabBar(selectedTab: .constant(.review), stage: .home, libraryCount: 0)
    }
}

#Preview("Connecting") {
    ConnectingOverlayView(hostLabel: "juejue-byte--musicscan.us-east.modal.run", onOpenSettings: {})
}
