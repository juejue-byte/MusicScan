import CoreGraphics
import SwiftUI

/// Extended Sky design tokens, procedural dithering/stippling textures, and brand components.
extension SkyTheme {
    static let sky400 = Color(red: 0.373, green: 0.682, blue: 0.922)     // #5FAEEB highlights
    static let skyHeroTop = Color(red: 0.859, green: 0.925, blue: 0.988) // #DBECFC welcome panel
    static let skyHeroBottom = Color(red: 0.816, green: 0.898, blue: 0.980) // #D0E5FA

    // Confidence flag semantics (color + shape so they read without color)
    static let glanceInk = Color(red: 0.541, green: 0.325, blue: 0.000)    // #8A5300
    static let glanceFill = Color(red: 1.000, green: 0.945, blue: 0.839)   // #FFF1D6
    static let glanceStroke = Color(red: 0.890, green: 0.608, blue: 0.106) // #E39B1B
    static let wrongInk = Color(red: 0.761, green: 0.212, blue: 0.169)     // #C2362B
    static let wrongFill = Color(red: 0.992, green: 0.910, blue: 0.902)    // #FDE8E6
    static let wrongStroke = Color(red: 0.827, green: 0.275, blue: 0.227)  // #D3463A

    // Practice dark surface & subtle controls
    static let practiceDock = Color(red: 0.055, green: 0.133, blue: 0.220)       // #0E2238
    static let practiceButton = Color(red: 0.125, green: 0.212, blue: 0.306)     // #20364E
    static let practiceSegmentBg = Color(red: 0.102, green: 0.184, blue: 0.275)  // #1A2F46
    static let parchment = Color(red: 0.949, green: 0.933, blue: 0.894)          // #F2EEE4 photo-like paper

    static let heroGradient = LinearGradient(
        colors: [
            Color(red: 0.075, green: 0.388, blue: 0.733),
            blue600,
            Color(red: 0.165, green: 0.545, blue: 0.894)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let canvasGradient = LinearGradient(
        colors: [sky25, Color(red: 0.935, green: 0.968, blue: 1.000)],
        startPoint: .top,
        endPoint: .bottom
    )

    static let welcomePanelGradient = LinearGradient(
        colors: [skyHeroTop, skyHeroBottom],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Procedural Stipple & Bayer Ordered-Dither Textures

/// Generates lightweight, GPU-cached procedural textures once per app launch so Sky gradients
/// never show 8-bit banding and surfaces carry subtle archival sheet-music stippling.
enum SkyTextureLibrary {
    /// Seamless 96x96 blue-noise-inspired ink micro-stipple tile for archival paper grain.
    static let paperStippleTile: CGImage? = makePaperStippleTile(size: 96)

    /// 4x4 normalized Bayer ordered-dithering threshold matrix (values in 0..<1).
    static let bayer4x4: [[Double]] = [
        [0.0 / 16.0, 8.0 / 16.0, 2.0 / 16.0, 10.0 / 16.0],
        [12.0 / 16.0, 4.0 / 16.0, 14.0 / 16.0, 6.0 / 16.0],
        [3.0 / 16.0, 11.0 / 16.0, 1.0 / 16.0, 9.0 / 16.0],
        [15.0 / 16.0, 7.0 / 16.0, 13.0 / 16.0, 5.0 / 16.0],
    ]

    private static func makePaperStippleTile(size: Int) -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        // Deep navy ink (#0E2238) premultiplied with subtle organic stipple alpha.
        let rBase: Double = 14.0
        let gBase: Double = 34.0
        let bBase: Double = 56.0

        for y in 0..<size {
            for x in 0..<size {
                // Interleaved gradient noise gives fine, isotropic stipple with zero tiling seams.
                let n1 = sin(Double(x) * 12.9898 + Double(y) * 78.233) * 43758.5453
                let f1 = n1 - floor(n1)
                let n2 = sin(Double(x) * 39.346 + Double(y) * 11.135) * 24634.6345
                let f2 = n2 - floor(n2)
                let bayer = bayer4x4[y & 3][x & 3]

                // Sparse fine ink stipple specks + micro-dither variation
                let combined = (f1 * 0.55 + f2 * 0.25 + bayer * 0.20)
                let alpha: Double
                if combined > 0.78 {
                    alpha = (combined - 0.78) / 0.22 * 0.85
                } else if combined < 0.14 {
                    alpha = 0.12
                } else {
                    alpha = 0.0
                }

                let idx = (y * size + x) * 4
                pixels[idx] = UInt8((rBase * alpha).rounded())
                pixels[idx + 1] = UInt8((gBase * alpha).rounded())
                pixels[idx + 2] = UInt8((bBase * alpha).rounded())
                pixels[idx + 3] = UInt8((255.0 * alpha).rounded())
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: size,
            height: size,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

/// Editorial Sky paper canvas with smooth gradient, subtle radial illumination, and
/// crisp 4x4 Bayer ordered-dithered halftone washes that give every screen tactile print craft.
struct SkyDitheredCanvas: View {
    var showTopStippleMist: Bool = true

    var body: some View {
        ZStack {
            SkyTheme.canvasGradient

            // Soft top-leading atmospheric light bloom
            RadialGradient(
                colors: [
                    SkyTheme.sky200.opacity(0.38),
                    SkyTheme.sky100.opacity(0.12),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 12,
                endRadius: 460
            )

            if showTopStippleMist {
                // Crisp top-trailing 4x4 Bayer ordered-dither wash
                StippledHalftoneWash(
                    tint: SkyTheme.blue600,
                    maxOpacity: 0.145,
                    dotSpacing: 6.0,
                    maxDotRadius: 1.45,
                    origin: .topTrailing
                )
                .frame(maxHeight: 340)
                .frame(maxHeight: .infinity, alignment: .top)

                // Subtle bottom-trailing halftone balance
                StippledHalftoneWash(
                    tint: SkyTheme.blue700,
                    maxOpacity: 0.08,
                    dotSpacing: 7.0,
                    maxDotRadius: 1.2,
                    origin: .bottomTrailing
                )
                .frame(maxHeight: 200)
                .frame(maxHeight: .infinity, alignment: .bottom)
            }

            // Seamless micro-stipple paper grain (eliminates gradient banding)
            if let tile = SkyTextureLibrary.paperStippleTile {
                Rectangle()
                    .fill(ImagePaint(image: Image(decorative: tile, scale: 2.0), scale: 1.0))
                    .opacity(0.065)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Bayer ordered-dithered halftone stipple accent that smoothly dissolves across a surface,
/// echoing fine lithograph music engraving and high-craft editorial print design.
struct StippledHalftoneWash: View {
    enum Origin {
        case topTrailing
        case bottomTrailing
        case topLeading
        case bottomEdge
    }

    var tint: Color = .white
    var maxOpacity: Double = 0.22
    var dotSpacing: CGFloat = 6.5
    var maxDotRadius: CGFloat = 1.45
    var origin: Origin = .topTrailing

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            guard size.width > 0, size.height > 0 else { return }
            let step = max(4.5, dotSpacing)
            let cols = Int(ceil(size.width / step))
            let rows = Int(ceil(size.height / step))
            let bayer = SkyTextureLibrary.bayer4x4

            for row in 0...rows {
                let y = CGFloat(row) * step + step * 0.5
                let ny = Double(y / size.height)
                for col in 0...cols {
                    let x = CGFloat(col) * step + step * 0.5
                    let nx = Double(x / size.width)

                    let intensity: Double
                    switch origin {
                    case .topTrailing:
                        let dx = 1.0 - nx
                        let dy = ny
                        let dist = sqrt(dx * dx * 0.85 + dy * dy * 1.15)
                        intensity = max(0.0, 1.0 - dist * 1.25)
                    case .bottomTrailing:
                        let dx = 1.0 - nx
                        let dy = 1.0 - ny
                        let dist = sqrt(dx * dx * 0.85 + dy * dy * 1.15)
                        intensity = max(0.0, 1.0 - dist * 1.2)
                    case .topLeading:
                        let dist = sqrt(nx * nx * 0.85 + ny * ny * 1.15)
                        intensity = max(0.0, 1.0 - dist * 1.25)
                    case .bottomEdge:
                        intensity = max(0.0, (ny - 0.25) / 0.75)
                    }

                    guard intensity > 0.03 else { continue }
                    let threshold = bayer[row & 3][col & 3]
                    // Ordered Bayer dithering + organic dot radius taper
                    let dithered = intensity * 1.12 - threshold * 0.58
                    guard dithered > 0.0 else { continue }

                    let radius = max(0.55, CGFloat(min(1.0, dithered * 1.25)) * maxDotRadius)
                    let alpha = min(1.0, dithered * 1.35) * maxOpacity
                    let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                    context.fill(Path(ellipseIn: rect), with: .color(tint.opacity(alpha)))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Tactile press-scale button style for primary and secondary cards so every interaction
/// feels physically responsive and smooth.
struct TactileCardButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.976

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1.0)
            .opacity(configuration.isPressed ? 0.94 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.76), value: configuration.isPressed)
    }
}

/// Crisp archival engraved-card surface with hairline border, inner top gleam, and soft two-tier elevation.
struct EngravedCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 18
    var fillColor: Color = .white

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fillColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.95), SkyTheme.line.opacity(0.85)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.9
                            )
                    )
            )
            .shadow(color: SkyTheme.navy900.opacity(0.032), radius: 2, y: 1)
            .shadow(color: SkyTheme.navy900.opacity(0.055), radius: 12, y: 5)
    }
}

/// Smooth horizontal light sweep for skeleton cards and loading placeholders.
struct SkyShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -0.8

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geo in
                    let width = max(geo.size.width, 1)
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.0),
                            Color.white.opacity(0.55),
                            Color.white.opacity(0.0)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(width: width * 0.72)
                    .offset(x: phase * width * 1.6)
                }
                .allowsHitTesting(false)
            }
            .clipped()
            .onAppear {
                withAnimation(.linear(duration: 1.35).repeatForever(autoreverses: false)) {
                    phase = 1.2
                }
            }
    }
}

extension View {
    func skyShimmer() -> some View {
        modifier(SkyShimmerModifier())
    }
}

/// Non-shifting 2.5pt animated hairline progress bar that glides cleanly along the top edge
/// without pushing layout content downward.
struct SkyTopProgressBar: View {
    var progress: Double? = nil
    @State private var slide: CGFloat = -0.45

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(SkyTheme.sky100.opacity(0.8))

                if let progress {
                    Capsule()
                        .fill(SkyTheme.heroGradient)
                        .frame(width: max(18, geo.size.width * min(max(progress, 0.05), 1.0)))
                        .animation(.easeOut(duration: 0.28), value: progress)
                } else {
                    Capsule()
                        .fill(SkyTheme.heroGradient)
                        .frame(width: geo.size.width * 0.36)
                        .offset(x: slide * geo.size.width)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                                slide = 0.64
                            }
                        }
                }
            }
        }
        .frame(height: 3)
        .clipped()
        .allowsHitTesting(false)
    }
}

extension View {
    func engravedCard(cornerRadius: CGFloat = 18, fill: Color = .white) -> some View {
        modifier(EngravedCardModifier(cornerRadius: cornerRadius, fillColor: fill))
    }
}

/// Renders the MusicScan brand logo from `Assets.xcassets` (`AppConfig.defaultLogoAssetName`, default `"BrandLogo"` / `icon-512.png`),
/// or falls back to the procedural Sky viewfinder + music note vector mark if `"vector"` is selected.
struct MusicScanLogoView: View {
    var size: CGFloat = 72
    var showShadow: Bool = true
    var overrideAssetName: String? = nil

    @AppStorage(AppConfig.logoAssetStorageKey) private var storedAssetName = AppConfig.defaultLogoAssetName

    private var activeAssetName: String {
        let name = (overrideAssetName ?? storedAssetName).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? AppConfig.defaultLogoAssetName : name
    }

    var body: some View {
        Group {
            if activeAssetName != "vector", let uiImage = UIImage(named: activeAssetName) {
                Image(uiImage: uiImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.28), lineWidth: max(0.8, size * 0.015))
                    )
                    .shadow(
                        color: showShadow ? SkyTheme.blue600.opacity(0.24) : .clear,
                        radius: size * 0.18,
                        y: size * 0.07
                    )
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                        .fill(SkyTheme.heroGradient)
                        .shadow(
                            color: showShadow ? SkyTheme.blue600.opacity(0.26) : .clear,
                            radius: size * 0.2,
                            y: size * 0.08
                        )

                    ViewfinderCornersShape(inset: size * 0.20, armLength: size * 0.18)
                        .stroke(
                            Color.white.opacity(0.92),
                            style: StrokeStyle(lineWidth: max(1.8, size * 0.052), lineCap: .round, lineJoin: .round)
                        )

                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.36, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .offset(x: -size * 0.015, y: size * 0.01)
                }
                .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Branded launch splash overlay displayed when first opening the app while connecting to the MusicScan server.
struct ServerLaunchSplashView: View {
    let hostLabel: String
    var onSkipToWorkspace: (() -> Void)? = nil

    @State private var pulse = false
    @State private var showSkipHint = false

    var body: some View {
        ZStack {
            SkyDitheredCanvas()
                .ignoresSafeArea()

            StaffLinesBackdrop(lineSpacing: 16)
                .opacity(0.65)

            VStack(spacing: 22) {
                Spacer()

                ZStack {
                    Circle()
                        .fill(SkyTheme.sky200.opacity(pulse ? 0.32 : 0.14))
                        .frame(width: pulse ? 148 : 124, height: pulse ? 148 : 124)

                    MusicScanLogoView(size: 96, showShadow: true)
                        .scaleEffect(pulse ? 1.02 : 0.98)
                }
                .animation(.easeInOut(duration: 1.35).repeatForever(autoreverses: true), value: pulse)

                VStack(spacing: 8) {
                    Text("MusicScan")
                        .font(.system(size: 30, weight: .black, design: .rounded))
                        .foregroundStyle(SkyTheme.navy900)

                    Text("Scan a page. Play it.")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(SkyTheme.slate600)
                }

                VStack(spacing: 12) {
                    HStack(spacing: 9) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(SkyTheme.blue600)

                        Text("Connecting to score server…")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(SkyTheme.blue700)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.white.opacity(0.92), in: Capsule())
                    .overlay(Capsule().stroke(SkyTheme.line, lineWidth: 1))
                    .shadow(color: SkyTheme.navy900.opacity(0.06), radius: 10, y: 4)

                    SkyTopProgressBar()
                        .frame(width: 180)
                        .clipShape(Capsule())
                }
                .padding(.top, 6)

                if showSkipHint, let onSkipToWorkspace {
                    Button(action: onSkipToWorkspace) {
                        Text("Continue while connecting in background →")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(SkyTheme.blue700)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(SkyTheme.sky50, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }

                Spacer()
            }
            .padding(24)
        }
        .onAppear {
            pulse = true
        }
        .task {
            try? await Task.sleep(for: .seconds(2.2))
            withAnimation(.easeOut(duration: 0.25)) {
                showSkipHint = true
            }
        }
    }
}

/// Reusable viewfinder corner brackets used in the logo, welcome artwork, and camera scanner.
struct ViewfinderCornersShape: Shape {
    let inset: CGFloat
    let armLength: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let left = rect.minX + inset
        let right = rect.maxX - inset
        let top = rect.minY + inset
        let bottom = rect.maxY - inset
        let r = min(armLength * 0.35, 10)

        // Top-left
        path.move(to: CGPoint(x: left, y: top + armLength))
        path.addLine(to: CGPoint(x: left, y: top + r))
        path.addQuadCurve(to: CGPoint(x: left + r, y: top), control: CGPoint(x: left, y: top))
        path.addLine(to: CGPoint(x: left + armLength, y: top))

        // Top-right
        path.move(to: CGPoint(x: right - armLength, y: top))
        path.addLine(to: CGPoint(x: right - r, y: top))
        path.addQuadCurve(to: CGPoint(x: right, y: top + r), control: CGPoint(x: right, y: top))
        path.addLine(to: CGPoint(x: right, y: top + armLength))

        // Bottom-right
        path.move(to: CGPoint(x: right, y: bottom - armLength))
        path.addLine(to: CGPoint(x: right, y: bottom - r))
        path.addQuadCurve(to: CGPoint(x: right - r, y: bottom), control: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: right - armLength, y: bottom))

        // Bottom-left
        path.move(to: CGPoint(x: left + armLength, y: bottom))
        path.addLine(to: CGPoint(x: left + r, y: bottom))
        path.addQuadCurve(to: CGPoint(x: left, y: bottom - r), control: CGPoint(x: left, y: bottom))
        path.addLine(to: CGPoint(x: left, y: bottom - armLength))

        return path
    }
}

/// Delicate five-line musical staff motif used behind launch and error states.
struct StaffLinesBackdrop: View {
    var lineSpacing: CGFloat = 14

    var body: some View {
        VStack(spacing: lineSpacing) {
            ForEach(0..<5, id: \.self) { _ in
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, SkyTheme.sky200.opacity(0.65), SkyTheme.sky200.opacity(0.65), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 1.2)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Gentle flowing five-line musical staff ribbon used on the Welcome illustration panel.
struct WavyStaffRibbon: View {
    var amplitude: CGFloat = 14
    var lineSpacing: CGFloat = 10
    var strokeColor: Color = SkyTheme.blue600.opacity(0.14)

    var body: some View {
        Canvas { context, size in
            for lineIndex in 0..<5 {
                let yOffset = CGFloat(lineIndex) * lineSpacing
                var path = Path()
                let steps = 48
                for step in 0...steps {
                    let progress = CGFloat(step) / CGFloat(steps)
                    let x = progress * size.width
                    let y = size.height * 0.5
                        + yOffset
                        - CGFloat(2) * lineSpacing
                        + sin(progress * .pi * 2.1 + 0.4) * amplitude
                    if step == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                context.stroke(path, with: .color(strokeColor), lineWidth: 1.4)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Circular user initial avatar matching Library sidebar, iPhone header, and Settings profile.
struct UserAvatarBadge: View {
    let initial: String
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            Circle()
                .fill(SkyTheme.blue600)
            Text(initial.uppercased())
                .font(.system(size: size * 0.44, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

/// Marigold "PRO" capsule badge used in Paywall and Settings.
struct ProPillBadge: View {
    var body: some View {
        Text("PRO")
            .font(.system(size: 11, weight: .black, design: .rounded))
            .tracking(0.5)
            .foregroundStyle(SkyTheme.navy900)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(SkyTheme.marigold, in: Capsule())
    }
}

/// Status badge used on Library score cards ("2 bars to check" or "Ready").
struct ScoreStatusBadge: View {
    let flaggedCount: Int

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(flaggedCount > 0 ? SkyTheme.glanceStroke : SkyTheme.sureInk)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(flaggedCount > 0 ? SkyTheme.glanceInk : SkyTheme.sureInk)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            flaggedCount > 0 ? SkyTheme.glanceFill : SkyTheme.sureFill,
            in: Capsule()
        )
    }

    private var label: String {
        if flaggedCount <= 0 {
            return "Ready"
        }
        return flaggedCount == 1 ? "1 bar to check" : "\(flaggedCount) bars to check"
    }
}

/// Soft rounded square icon container matching Welcome, Sign in, Paywall, and Settings wireframes.
struct IconTileBadge: View {
    let systemName: String
    var foreground: Color = SkyTheme.blue600
    var background: Color = SkyTheme.sky50
    var size: CGFloat = 36
    var cornerRadius: CGFloat = 10

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background(background, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

#Preview("Sky Brand Elements") {
    ZStack {
        SkyTheme.canvasGradient.ignoresSafeArea()
        StaffLinesBackdrop()
        VStack(spacing: 16) {
            MusicScanLogoView(size: 84)
            Text("MusicScan")
                .font(.system(size: 32, weight: .black, design: .rounded))
                .foregroundStyle(SkyTheme.navy900)
            HStack(spacing: 10) {
                ScoreStatusBadge(flaggedCount: 2)
                ScoreStatusBadge(flaggedCount: 0)
                ProPillBadge()
            }
        }
    }
}
