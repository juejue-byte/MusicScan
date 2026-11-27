import AuthenticationServices
import SwiftUI

/// Clean, single-screen Welcome experience with zero horizontal scrolling and safe-area-respecting
/// framing across all iPhone and iPad sizes. Leads into real Supabase Sign-In (`AuthManager`)
/// or guest mode before entering the live MusicScan workspace.
struct WelcomeFlowView: View {
    let onComplete: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var auth = AuthManager.shared
    @State private var showSignInSheet = false

    private var isCompact: Bool {
        horizontalSizeClass == .compact
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let useModalCardSignIn = width >= 540 && !isCompact

            ZStack {
                SkyDitheredCanvas()
                    .ignoresSafeArea()

                if width >= 820 {
                    wideTwoColumnLayout(size: geo.size)
                } else if width >= 540 {
                    mediumFoldableOrPortraitTabletLayout(size: geo.size)
                } else {
                    compactPhoneLayout(size: geo.size)
                }

                // Centered Sign-In card on iPad / unfolded Duo Inner over dimmed Welcome
                if showSignInSheet && useModalCardSignIn {
                    Color.black.opacity(0.36)
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.2)) {
                                showSignInSheet = false
                            }
                        }

                    SignInSheetView(
                        isModalCard: true,
                        onClose: {
                            withAnimation(.easeOut(duration: 0.2)) {
                                showSignInSheet = false
                            }
                        },
                        onContinue: {
                            showSignInSheet = false
                            onComplete()
                        }
                    )
                    .frame(maxWidth: min(width - 40, 460))
                    .padding(20)
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showSignInSheet)
            .sheet(isPresented: Binding(
                get: { showSignInSheet && !useModalCardSignIn },
                set: { if !$0 { showSignInSheet = false } }
            )) {
                SignInSheetView(
                    isModalCard: false,
                    onClose: { showSignInSheet = false },
                    onContinue: {
                        showSignInSheet = false
                        onComplete()
                    }
                )
                #if os(iOS)
                .presentationDetents([.large])
                .presentationCornerRadius(28)
                #endif
            }
        }
    }

    // MARK: - iPhone & iPhone Duo Outer Layout (Zero Clipping, Safe-Area Pinned CTA)

    private func compactPhoneLayout(size: CGSize) -> some View {
        let isTight = size.width < 380 || size.height < 740
        let hPad: CGFloat = isTight ? 18 : 22
        return ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: isTight ? 14 : 18) {
                heroIllustrationCard(compact: true, tight: true)

                copyAndFeaturesSection(tight: true, headlineSize: isTight ? 27 : 31)
            }
            .padding(.horizontal, hPad)
            .padding(.top, isTight ? 8 : 12)
            .padding(.bottom, 12)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ctaSection(fullWidthButton: true)
                .padding(.horizontal, hPad)
                .padding(.top, 10)
                .padding(.bottom, 10)
                .frame(maxWidth: 480)
                .frame(maxWidth: .infinity)
                .background(
                    LinearGradient(
                        colors: [SkyTheme.sky25.opacity(0.0), SkyTheme.sky25.opacity(0.96), SkyTheme.sky25],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .ignoresSafeArea(edges: .bottom)
                )
        }
    }

    // MARK: - iPhone Duo Inner & Portrait Tablet Layout

    private func mediumFoldableOrPortraitTabletLayout(size: CGSize) -> some View {
        let isShortInner = size.height < 760
        return ScrollView {
            if isShortInner && size.width >= 580 {
                HStack(alignment: .center, spacing: 24) {
                    heroIllustrationCard(compact: false, tight: true)
                        .frame(width: min(size.width * 0.42, 300))

                    VStack(alignment: .leading, spacing: 18) {
                        copyAndFeaturesSection(tight: true, headlineSize: 32)
                        ctaSection(fullWidthButton: false)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(minHeight: size.height, alignment: .center)
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    heroIllustrationCard(compact: true, tight: false)
                    copyAndFeaturesSection(tight: false, headlineSize: 38)
                    ctaSection(fullWidthButton: false)
                }
                .frame(maxWidth: 540, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(minHeight: size.height, alignment: .center)
                .frame(maxWidth: .infinity)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: - iPad Wide Layout (Solid 2-Column)

    private func wideTwoColumnLayout(size: CGSize) -> some View {
        HStack(spacing: 0) {
            ZStack {
                SkyTheme.welcomePanelGradient
                    .ignoresSafeArea()

                StippledHalftoneWash(
                    tint: SkyTheme.blue600,
                    maxOpacity: 0.14,
                    dotSpacing: 6.5,
                    maxDotRadius: 1.4,
                    origin: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack {
                    WavyStaffRibbon(amplitude: 10, lineSpacing: 8)
                        .frame(height: 64)
                    Spacer()
                    WavyStaffRibbon(amplitude: 10, lineSpacing: 8)
                        .frame(height: 64)
                }
                .padding(.vertical, 52)

                heroIllustrationCard(compact: false, tight: false)
                    .padding(36)
            }
            .frame(width: min(size.width * 0.44, 520))

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    copyAndFeaturesSection(tight: false, headlineSize: 44)
                    ctaSection(fullWidthButton: false)
                }
                .frame(maxWidth: 480, alignment: .leading)
                .padding(.horizontal, 44)
                .padding(.vertical, 36)
                .frame(minHeight: size.height, alignment: .center)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(SkyTheme.sky25)
        }
    }

    // MARK: - Copy, Features & Actions

    private func copyAndFeaturesSection(tight: Bool, headlineSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: tight ? 14 : 20) {
            HStack(spacing: 10) {
                MusicScanLogoView(size: tight ? 34 : 40, showShadow: false)
                Text("MusicScan")
                    .font(.system(size: tight ? 18 : 20, weight: .bold, design: .rounded))
                    .foregroundStyle(SkyTheme.navy900)
            }

            VStack(alignment: .leading, spacing: tight ? 6 : 10) {
                Text("Scan it. \(Text("Fix it.").foregroundStyle(SkyTheme.blue600))\nPlay it.")
                    .font(.system(size: headlineSize, weight: .black, design: .rounded))
                    .foregroundStyle(SkyTheme.navy900)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Turn printed sheet music or PDFs into playable scores you can edit and export.")
                    .font(.system(size: tight ? 14.5 : (isCompact ? 15.5 : 17)))
                    .foregroundStyle(SkyTheme.slate600)
                    .lineSpacing(tight ? 2 : 3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: tight ? 11 : 16) {
                featureRow(
                    icon: "doc.viewfinder",
                    foreground: SkyTheme.blue600,
                    background: SkyTheme.sky50,
                    title: "Scan pages",
                    detail: "Auto-crops edges, rotates sideways photos, and removes pen marks.",
                    tight: tight
                )
                featureRow(
                    icon: "checkmark.seal",
                    foreground: SkyTheme.glanceInk,
                    background: SkyTheme.glanceFill,
                    title: "Quick bar review",
                    detail: "Uncertain bars are highlighted beside your original photo.",
                    tight: tight
                )
                featureRow(
                    icon: "play.fill",
                    foreground: .white,
                    background: SkyTheme.navy900,
                    title: "Play & export",
                    detail: "Hear piano playback, loop bars, or export MusicXML and MIDI.",
                    tight: tight
                )
            }
            .padding(.top, tight ? 2 : 4)
        }
    }

    private func ctaSection(fullWidthButton: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Button {
                    if auth.isGuest {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                            showSignInSheet = true
                        }
                    } else {
                        onComplete()
                    }
                } label: {
                    Text("Get started")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28)
                        .frame(height: 50)
                        .frame(maxWidth: fullWidthButton ? .infinity : nil)
                        .background(SkyTheme.heroGradient, in: Capsule())
                        .shadow(color: SkyTheme.blue600.opacity(0.28), radius: 12, y: 5)
                }
                .buttonStyle(TactileCardButtonStyle())

                if !fullWidthButton {
                    Button {
                        onComplete()
                    } label: {
                        Text("Skip sign-in")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(SkyTheme.blue600)
                            .padding(.horizontal, 12)
                            .frame(height: 44)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                Text("Your first full page is free.")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(SkyTheme.slate600)

                if fullWidthButton {
                    Spacer()
                    Button {
                        onComplete()
                    } label: {
                        Text("Skip sign-in")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(SkyTheme.blue600)
                            .padding(.horizontal, 8)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 4)
    }

    private func featureRow(
        icon: String,
        foreground: Color,
        background: Color,
        title: String,
        detail: String,
        tight: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: tight ? 11 : 14) {
            IconTileBadge(
                systemName: icon,
                foreground: foreground,
                background: background,
                size: tight ? 36 : 40,
                cornerRadius: 10
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: tight ? 14.5 : 15.5, weight: .bold))
                    .foregroundStyle(SkyTheme.navy900)
                Text(detail)
                    .font(.system(size: tight ? 13 : 14))
                    .foregroundStyle(SkyTheme.slate600)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Self-Contained Framed Score Card Illustration (Never Overflows or Clips)

    private func heroIllustrationCard(compact: Bool, tight: Bool) -> some View {
        VStack(spacing: tight ? 10 : 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.white)
                    .shadow(color: SkyTheme.navy900.opacity(0.10), radius: 20, y: 8)

                VStack(spacing: compact || tight ? 8 : 14) {
                    VStack(spacing: 2) {
                        Text("Sonata facile")
                            .font(.system(size: compact || tight ? 13 : 15, weight: .bold, design: .serif))
                            .foregroundStyle(SkyTheme.navy900)
                        Text("W. A. Mozart, K. 545")
                            .font(.system(size: compact || tight ? 9.5 : 10.5, design: .serif))
                            .foregroundStyle(SkyTheme.slate600)
                    }

                    // Clean vector staff motif inside the sheet card
                    VStack(spacing: compact || tight ? 12 : 18) {
                        miniStaffRow(highlightedBar: 1, highlightColor: SkyTheme.sky100)
                        miniStaffRow(highlightedBar: 2, highlightColor: SkyTheme.glanceFill)
                        if !compact && !tight {
                            miniStaffRow(highlightedBar: nil, highlightColor: .clear)
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .padding(.vertical, compact || tight ? 14 : 24)
                .padding(.horizontal, 12)

                ViewfinderCornersShape(inset: 10, armLength: compact || tight ? 20 : 30)
                    .stroke(
                        SkyTheme.blue600.opacity(0.85),
                        style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round)
                    )
            }
            .frame(maxWidth: compact ? .infinity : 320)
            .frame(height: tight ? 128 : (compact ? 172 : 340))

            // Responsive status pills: side-by-side when space allows, clean stack on narrow Duo Outer
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    playbackStatusPill
                    checkStatusPill
                }
                VStack(spacing: 6) {
                    playbackStatusPill
                    checkStatusPill
                }
            }
        }
        .padding(compact ? (tight ? 12 : 16) : 0)
        .background {
            if compact {
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(SkyTheme.welcomePanelGradient)
                    StippledHalftoneWash(
                        tint: SkyTheme.blue600,
                        maxOpacity: 0.14,
                        dotSpacing: 6.5,
                        maxDotRadius: 1.35,
                        origin: .topTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
            }
        }
    }

    private var playbackStatusPill: some View {
        HStack(spacing: 6) {
            Image(systemName: "play.fill")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(SkyTheme.blue600, in: Circle())
            Text("♩ = 96 · Loop 1–4")
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.leading, 5)
        .padding(.trailing, 11)
        .padding(.vertical, 5)
        .background(SkyTheme.navy900, in: Capsule())
    }

    private var checkStatusPill: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SkyTheme.sureInk)
            Text("2 bars to check")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(SkyTheme.navy900)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(.white, in: Capsule())
        .overlay(Capsule().stroke(SkyTheme.line, lineWidth: 1))
    }

    private func miniStaffRow(highlightedBar: Int?, highlightColor: Color) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                if let bar = highlightedBar {
                    let barW = w / 3
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(highlightColor)
                        .frame(width: barW - 4, height: h + 8)
                        .position(x: barW * (CGFloat(bar) + 0.5), y: h * 0.5)
                }

                VStack(spacing: max(3, h / 5)) {
                    ForEach(0..<5, id: \.self) { _ in
                        Rectangle()
                            .fill(SkyTheme.navy900.opacity(0.28))
                            .frame(height: 0.8)
                    }
                }

                HStack {
                    ForEach(0..<4, id: \.self) { idx in
                        Rectangle()
                            .fill(SkyTheme.navy900.opacity(0.4))
                            .frame(width: 1, height: h)
                        if idx < 3 {
                            Spacer()
                        }
                    }
                }

                // Subtle notehead silhouette dots
                HStack(spacing: 0) {
                    ForEach(0..<9, id: \.self) { i in
                        let offsets: [CGFloat] = [-6, -2, 2, -4, 4, 0, -5, 3, -1]
                        Ellipse()
                            .fill(SkyTheme.navy900.opacity(0.75))
                            .frame(width: 6.5, height: 4.8)
                            .rotationEffect(.degrees(-18))
                            .offset(y: offsets[i % offsets.count])
                        if i < 8 { Spacer() }
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .frame(height: 24)
    }
}

// MARK: - Real Supabase Sign-In Sheet (Apple, Google, Email Magic Link + OTP)

struct SignInSheetView: View {
    var isModalCard: Bool = true
    let onClose: () -> Void
    let onContinue: () -> Void

    @State private var auth = AuthManager.shared
    @State private var showEmailForm = false
    @State private var isExistingAccountMode = false
    @State private var email = ""
    @State private var verificationCode = ""
    @State private var linkSent = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(SkyTheme.slate600)
                        .frame(width: 36, height: 36)
                        .background(SkyTheme.sky50, in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 18) {
                    MusicScanLogoView(size: 60)

                    VStack(spacing: 8) {
                        Text("Keep your music safe")
                            .font(.system(size: 25, weight: .black, design: .rounded))
                            .foregroundStyle(SkyTheme.navy900)
                            .multilineTextAlignment(.center)

                        Text("Sign in so your subscription and account carry across every iPad and iPhone.")
                            .font(.system(size: 14.5))
                            .foregroundStyle(SkyTheme.slate600)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 6)

                    if let session = auth.session, !session.isAnonymous {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(SkyTheme.sureInk)
                            Text("Signed in as \(session.displayLabel)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(SkyTheme.sureInk)
                            Spacer()
                        }
                        .padding(12)
                        .background(SkyTheme.sureFill, in: RoundedRectangle(cornerRadius: 12))
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            benefitRow(icon: "icloud", text: "Your account and Pro plan follow you across devices")
                            benefitRow(icon: "shield", text: "Private by default — we never share your photos or email")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)

                        if auth.isGuest {
                            Picker("Sign-in mode", selection: $isExistingAccountMode) {
                                Text("Save this device").tag(false)
                                Text("Sign into existing").tag(true)
                            }
                            .pickerStyle(.segmented)
                        }

                        VStack(spacing: 10) {
                            // Real Native Sign in with Apple -> Supabase ID Token
                            Button {
                                auth.signInWithApple()
                            } label: {
                                HStack(spacing: 8) {
                                    if auth.isBusy {
                                        ProgressView().tint(.white)
                                    } else {
                                        Image(systemName: "apple.logo")
                                            .font(.system(size: 17, weight: .semibold))
                                    }
                                    Text("Sign in with Apple")
                                        .font(.system(size: 16, weight: .semibold))
                                }
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(Color.black, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(auth.isBusy)

                            // Real Google OAuth (PKCE via ASWebAuthenticationSession)
                            Button {
                                auth.signInWithGoogle(linkToGuest: !isExistingAccountMode)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "globe")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(SkyTheme.blue600)
                                    Text("Continue with Google")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(SkyTheme.navy900)
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(SkyTheme.sky50, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(SkyTheme.line, lineWidth: 1.2)
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(auth.isBusy)

                            // Real Email Magic Link & 6-digit OTP via Supabase Auth
                            Button {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                                    showEmailForm.toggle()
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "envelope")
                                        .font(.system(size: 16, weight: .medium))
                                    Text("Continue with email")
                                        .font(.system(size: 16, weight: .semibold))
                                }
                                .foregroundStyle(SkyTheme.navy900)
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                                .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(SkyTheme.line, lineWidth: 1.2)
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(auth.isBusy)

                            if showEmailForm {
                                emailSignInBox
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }

                    if let error = auth.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(SkyTheme.wrongInk)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(SkyTheme.wrongFill, in: RoundedRectangle(cornerRadius: 10))
                    } else if let status = auth.statusMessage {
                        Label(status, systemImage: "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(SkyTheme.sureInk)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(SkyTheme.sureFill, in: RoundedRectangle(cornerRadius: 10))
                    }

                    Button {
                        Task {
                            if auth.session == nil {
                                await auth.start()
                            }
                            onContinue()
                        }
                    } label: {
                        Text(auth.isGuest ? "Not now — continue as guest" : "Continue to MusicScan")
                            .font(.system(size: 15.5, weight: .semibold))
                            .foregroundStyle(SkyTheme.blue600)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    VStack(spacing: 4) {
                        Text("Guest mode stores a private account on this device. You can link Apple, Google, or email later in Settings.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(SkyTheme.slate600)
                            .multilineTextAlignment(.center)

                        HStack(spacing: 4) {
                            Text("By continuing you agree to the")
                                .foregroundStyle(SkyTheme.slate600)
                            Link("Terms", destination: AppConfig.termsURL)
                                .underline()
                                .foregroundStyle(SkyTheme.blue600)
                            Text("and")
                                .foregroundStyle(SkyTheme.slate600)
                            Link("Privacy Policy", destination: AppConfig.privacyURL)
                                .underline()
                                .foregroundStyle(SkyTheme.blue600)
                        }
                        .font(.system(size: 11.5))
                    }
                    .padding(.top, 2)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: isModalCard ? 28 : 0, style: .continuous)
                .fill(.white)
                .shadow(color: isModalCard ? SkyTheme.navy900.opacity(0.22) : .clear, radius: 34, y: 18)
        )
        .onChange(of: auth.isGuest) { _, isGuest in
            if !isGuest {
                onContinue()
            }
        }
    }

    private func benefitRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            IconTileBadge(systemName: icon, foreground: SkyTheme.blue600, background: SkyTheme.sky50, size: 32, cornerRadius: 9)
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(SkyTheme.navy900)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emailSignInBox: some View {
        VStack(spacing: 10) {
            TextField("you@example.com", text: $email)
                #if os(iOS)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                #endif
                .textContentType(.emailAddress)
                .autocorrectionDisabled()
                .padding(.horizontal, 14)
                .frame(height: 44)
                .background(SkyTheme.sky25, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(SkyTheme.line, lineWidth: 1)
                )

            Button {
                Task {
                    linkSent = await auth.sendEmailLink(email, linkToGuest: !isExistingAccountMode)
                }
            } label: {
                HStack(spacing: 8) {
                    if auth.isBusy { ProgressView().tint(.white) }
                    Text(linkSent ? "Send Sign-In Link Again" : "Send Sign-In Link")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(SkyTheme.blue600, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(auth.isBusy || !email.contains("@"))

            if linkSent {
                HStack(spacing: 8) {
                    TextField("6-digit code", text: $verificationCode)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                        .textContentType(.oneTimeCode)
                        .padding(.horizontal, 12)
                        .frame(height: 42)
                        .background(SkyTheme.sky25, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(SkyTheme.line, lineWidth: 1))

                    Button("Verify") {
                        Task {
                            let ok = await auth.verifyEmailCode(
                                email,
                                code: verificationCode,
                                linkToGuest: !isExistingAccountMode
                            )
                            if ok { onContinue() }
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 42)
                    .background(SkyTheme.sureInk, in: RoundedRectangle(cornerRadius: 10))
                    .disabled(auth.isBusy || verificationCode.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(14)
        .background(SkyTheme.sky50.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

#Preview("Welcome") {
    WelcomeFlowView(onComplete: {})
}
