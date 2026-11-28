import PencilKit
import SwiftUI

// MARK: - Emil Design Eng Tactile Button Style

/// Subtle 0.96 scale press feedback with fast 150ms ease-out curve.
struct PressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var pressedScale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1.0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.15),
                value: configuration.isPressed
            )
    }
}

// MARK: - Vector Music Notation Duration Glyphs (Zero Missing-Font [?] Tofu Boxes)

/// High-precision vector renderer for music note durations (`whole`, `half`, `quarter`, `eighth`, `16th`).
/// Guarantees crisp, engraved notation symbols on every iOS device without relying on Unicode Musical Symbols (`U+1D15x`)
/// that are missing from SF Pro and render as `[?]` boxes.
struct MusicDurationGlyphView: View {
    let durationID: String
    let color: Color

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let headW: CGFloat = 8.8
            let headH: CGFloat = 6.2
            let tilt = Angle.degrees(-22)

            switch durationID {
            case "whole":
                // Engraved hollow whole note with thick side crescents
                let cx = w * 0.5
                let cy = h * 0.54
                var outer = Path()
                outer.addEllipse(in: CGRect(x: cx - 5.2, y: cy - 3.6, width: 10.4, height: 7.2))
                context.stroke(outer, with: .color(color), lineWidth: 2.1)

            case "half":
                // Hollow tilted notehead + vertical stem
                let headX = w * 0.44
                let headY = h * 0.69
                context.drawLayer { layer in
                    layer.translateBy(x: headX, y: headY)
                    layer.rotate(by: tilt)
                    let rect = CGRect(x: -headW / 2, y: -headH / 2, width: headW, height: headH)
                    layer.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: 1.85)
                }
                var stem = Path()
                let stemX = headX + headW * 0.40
                stem.move(to: CGPoint(x: stemX, y: headY - 1))
                stem.addLine(to: CGPoint(x: stemX, y: h * 0.18))
                context.stroke(stem, with: .color(color), style: StrokeStyle(lineWidth: 1.65, lineCap: .round))

            case "quarter":
                // Filled tilted notehead + vertical stem
                let headX = w * 0.44
                let headY = h * 0.69
                context.drawLayer { layer in
                    layer.translateBy(x: headX, y: headY)
                    layer.rotate(by: tilt)
                    let rect = CGRect(x: -headW / 2, y: -headH / 2, width: headW, height: headH)
                    layer.fill(Path(ellipseIn: rect), with: .color(color))
                }
                var stem = Path()
                let stemX = headX + headW * 0.40
                stem.move(to: CGPoint(x: stemX, y: headY - 1))
                stem.addLine(to: CGPoint(x: stemX, y: h * 0.18))
                context.stroke(stem, with: .color(color), style: StrokeStyle(lineWidth: 1.65, lineCap: .round))

            case "eighth":
                // Filled notehead + stem + single engraved flag
                let headX = w * 0.40
                let headY = h * 0.70
                context.drawLayer { layer in
                    layer.translateBy(x: headX, y: headY)
                    layer.rotate(by: tilt)
                    let rect = CGRect(x: -headW / 2, y: -headH / 2, width: headW, height: headH)
                    layer.fill(Path(ellipseIn: rect), with: .color(color))
                }
                let stemX = headX + headW * 0.39
                let topY = h * 0.18
                var stem = Path()
                stem.move(to: CGPoint(x: stemX, y: headY - 1))
                stem.addLine(to: CGPoint(x: stemX, y: topY))
                context.stroke(stem, with: .color(color), style: StrokeStyle(lineWidth: 1.65, lineCap: .round))

                var flag = Path()
                flag.move(to: CGPoint(x: stemX, y: topY))
                flag.addCurve(
                    to: CGPoint(x: stemX + 6.2, y: topY + 8.5),
                    control1: CGPoint(x: stemX + 4.8, y: topY + 1.8),
                    control2: CGPoint(x: stemX + 6.8, y: topY + 5.2)
                )
                context.stroke(flag, with: .color(color), style: StrokeStyle(lineWidth: 1.85, lineCap: .round))

            default: // "16th"
                // Filled notehead + stem + double engraved flags
                let headX = w * 0.40
                let headY = h * 0.72
                context.drawLayer { layer in
                    layer.translateBy(x: headX, y: headY)
                    layer.rotate(by: tilt)
                    let rect = CGRect(x: -headW / 2, y: -headH / 2, width: headW, height: headH)
                    layer.fill(Path(ellipseIn: rect), with: .color(color))
                }
                let stemX = headX + headW * 0.39
                let topY = h * 0.16
                var stem = Path()
                stem.move(to: CGPoint(x: stemX, y: headY - 1))
                stem.addLine(to: CGPoint(x: stemX, y: topY))
                context.stroke(stem, with: .color(color), style: StrokeStyle(lineWidth: 1.65, lineCap: .round))

                for offset in [0.0, 4.6] {
                    var flag = Path()
                    let y0 = topY + offset
                    flag.move(to: CGPoint(x: stemX, y: y0))
                    flag.addCurve(
                        to: CGPoint(x: stemX + 6.2, y: y0 + 7.2),
                        control1: CGPoint(x: stemX + 4.8, y: y0 + 1.5),
                        control2: CGPoint(x: stemX + 6.6, y: y0 + 4.4)
                    )
                    context.stroke(flag, with: .color(color), style: StrokeStyle(lineWidth: 1.75, lineCap: .round))
                }
            }
        }
        .frame(width: 22, height: 22)
        .allowsHitTesting(false)
    }
}

// MARK: - Native PencilKit Ink Overlay (Persisted to LocalScoreStore)

#if os(iOS)
struct NativePencilCanvasView: UIViewRepresentable {
    let scoreID: String
    let isDrawingEnabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(scoreID: scoreID)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: UIColor(red: 0.76, green: 0.21, blue: 0.17, alpha: 0.92), width: 2.8)
        canvas.delegate = context.coordinator
        canvas.isUserInteractionEnabled = isDrawingEnabled
        if !scoreID.isEmpty {
            canvas.drawing = LocalScoreStore.shared.loadInkDrawing(for: scoreID)
        }
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        canvas.isUserInteractionEnabled = isDrawingEnabled
        if context.coordinator.scoreID != scoreID {
            context.coordinator.isReloading = true
            context.coordinator.scoreID = scoreID
            canvas.drawing = scoreID.isEmpty ? PKDrawing() : LocalScoreStore.shared.loadInkDrawing(for: scoreID)
            context.coordinator.isReloading = false
        }
    }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var scoreID: String
        var isReloading = false

        init(scoreID: String) {
            self.scoreID = scoreID
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isReloading, !scoreID.isEmpty else { return }
            LocalScoreStore.shared.saveInkDrawing(canvasView.drawing, for: scoreID)
        }
    }
}
#endif

// MARK: - Native SwiftUI Score Editor Chrome (iPhone Compact Dock + iPad 3-Region Studio)

/// Wraps the embedded local-first VexFlow canvas with native SwiftUI navigation and docks:
/// - **iPhone (`.compact`)**: Single 44pt top nav bar, strictly-constrained inline measure photo comparison strip in `Fix` mode,
///   full-bleed VexFlow score canvas below so both the original scan and the editable score of Bar N are visible simultaneously,
///   and a single adaptive 3-mode bottom dock (`Play` / `Fix` / `Edit`).
/// - **iPad (`.regular`)**: Unified 52pt Studio top bar and 3-region split workspace (Left: Synchronized Original Scan,
///   Center: Editable Score Canvas + Apple Pencil Ink layer, Right: Always-On Fix It Queue + Duration & Pitch palette).
struct ScoreEditorChromeOverlay: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Bindable var bridge: MusicScanBridgeController
    var store = LocalScoreStore.shared

    @State private var showRenameAlert = false
    @State private var renameDraft = ""
    @State private var showTempoPopover = false

    private var fastAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.18)
    }

    var body: some View {
        GeometryReader { geo in
            let isStudioLayout = (horizontalSizeClass == .regular && geo.size.width >= 740)

            Group {
                if isStudioLayout {
                    iPadStudioOverlay(size: geo.size)
                } else {
                    iPhoneCompactOverlay(size: geo.size)
                }
            }
            .animation(fastAnimation, value: bridge.editorMode)
            .animation(fastAnimation, value: bridge.showiPadPhotoPane)
        }
        .alert("Rename Score", isPresented: $showRenameAlert) {
            TextField("Score title", text: $renameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                bridge.renameActiveScore(to: renameDraft)
            }
        } message: {
            Text("Used in Your Music and when exporting to MuseScore or MIDI.")
        }
    }

    // MARK: - iPhone (.compact): Single 44pt Top Bar + Strictly-Sized Fix Measure Strip + Adaptive Bottom Dock

    private func iPhoneCompactOverlay(size: CGSize) -> some View {
        VStack(spacing: 0) {
            iPhoneTopNavigationBar

            if bridge.editorMode == .fix {
                iPhoneFixItPhotoCompareStrip
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Center pass-through viewport where the live editable VexFlow score canvas lives
            Spacer(minLength: 0)

            iPhoneAdaptiveBottomDock
        }
    }

    private var iPhoneTopNavigationBar: some View {
        HStack(spacing: 10) {
            Button {
                bridge.showLibraryHome()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .bold))
                    Text("Scores")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(SkyTheme.blue600)
                .frame(height: 36)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Back to Scores")

            Spacer(minLength: 4)

            titleDropdownMenu

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                Button {
                    bridge.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(bridge.canUndo ? SkyTheme.navy900 : SkyTheme.slate600.opacity(0.4))
                        .frame(width: 34, height: 34)
                        .background(SkyTheme.sky50, in: Circle())
                        .overlay(Circle().stroke(SkyTheme.line, lineWidth: 0.8))
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(!bridge.canUndo)
                .accessibilityLabel("Undo")

                exportMenuButton(compact: true)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(
            SkyTheme.sky25.opacity(0.96)
                .background(.ultraThinMaterial)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(SkyTheme.line.opacity(0.85))
                        .frame(height: 0.75)
                }
        )
    }

    private var titleDropdownMenu: some View {
        Menu {
            Button {
                renameDraft = bridge.documentTitle.isEmpty ? "Score" : bridge.documentTitle
                showRenameAlert = true
            } label: {
                Label("Rename Score…", systemImage: "pencil")
            }

            Button {
                bridge.openPagesSheet()
            } label: {
                Label("Pages (\(bridge.pageCount))", systemImage: "square.grid.2x2")
            }

            if bridge.pageCount > 1 {
                Button {
                    bridge.stepPage(-1)
                } label: {
                    Label("Previous Page", systemImage: "chevron.up")
                }
                .disabled(bridge.activePageIndex <= 0)

                Button {
                    bridge.stepPage(1)
                } label: {
                    Label("Next Page", systemImage: "chevron.down")
                }
                .disabled(bridge.activePageIndex >= bridge.pageCount - 1)
            }

            Divider()

            Button {
                bridge.adjustPageEdges()
            } label: {
                Label("Adjust Page Edges", systemImage: "crop")
            }

            Button {
                bridge.retakePagePhoto()
            } label: {
                Label("Retake Photo", systemImage: "camera.viewfinder")
            }

            Button {
                bridge.openKeyTimeTranspose()
            } label: {
                Label("Key, Time & Transpose", systemImage: "tuningfork")
            }

            Divider()

            Button {
                bridge.exportScore(format: "xml")
            } label: {
                Label("Export MusicXML (.musicxml)", systemImage: "doc.text")
            }

            Button {
                bridge.exportScore(format: "mid")
            } label: {
                Label("Export MIDI (.mid)", systemImage: "pianokeys")
            }
        } label: {
            HStack(spacing: 4) {
                Text(bridge.documentTitle.isEmpty ? "Untitled Score" : bridge.documentTitle)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(SkyTheme.navy900)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if bridge.pageCount > 1 {
                    Text("· P.\(bridge.activePageIndex + 1)")
                        .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(SkyTheme.blue700)
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(SkyTheme.slate600)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color.white.opacity(0.9), in: Capsule())
            .overlay(Capsule().stroke(SkyTheme.line, lineWidth: 0.8))
        }
        .accessibilityLabel("Score Actions Menu")
    }

    private func exportMenuButton(compact: Bool) -> some View {
        Menu {
            Button {
                bridge.exportScore(format: "xml")
            } label: {
                Label("Export MusicXML (.musicxml)", systemImage: "doc.text")
            }

            Button {
                bridge.exportScore(format: "mid")
            } label: {
                Label("Export MIDI (.mid)", systemImage: "pianokeys")
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                if !compact {
                    Text("Export")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                }
            }
            .foregroundStyle(SkyTheme.blue700)
            .padding(.horizontal, compact ? 0 : 12)
            .frame(width: compact ? 34 : nil, height: 34)
            .background(SkyTheme.sky50, in: Capsule())
            .overlay(Capsule().stroke(SkyTheme.sky200, lineWidth: 0.9))
        }
        .accessibilityLabel("Export Score")
    }

    /// Shown directly below the 44pt top bar when `Fix` mode is active on iPhone.
    /// Strictly constrained to a compact height (`134pt` default, `174pt` expanded) so the original photo crop of Bar N
    /// sits directly above the live editable VexFlow score of Bar N — never expanding or covering the score canvas.
    private var iPhoneFixItPhotoCompareStrip: some View {
        let croppedImage = store.croppedBarImage(
            for: bridge.activeScoreID,
            pageIndex: bridge.activePageIndex,
            jobID: bridge.activePageJobID,
            cropRect: bridge.activeBarCropRect
        )
        let fullPageImage = store.pageImage(
            for: bridge.activeScoreID,
            pageIndex: bridge.activePageIndex,
            jobID: bridge.activePageJobID
        )
        let isBad = (bridge.activeFlagLevel == "bad")
        let highlightColor = isBad ? SkyTheme.wrongInk : SkyTheme.marigold
        let photoHeight: CGFloat = bridge.isFixPhotoExpanded ? 116 : 76

        return VStack(alignment: .leading, spacing: 5) {
            // Top Header: Bar Number + Concise Flag Reason + Full Page / Zoom Toggles
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(highlightColor)
                        .frame(width: 6.5, height: 6.5)
                    Text("Bar \(bridge.activeFlagBarNumber) · Original Photo")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(SkyTheme.navy900)
                }

                if !bridge.activeFlagReason.isEmpty {
                    Text("· \(bridge.activeFlagReason)")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(SkyTheme.slate600)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button {
                    withAnimation(fastAnimation) {
                        bridge.showFullPageInFix.toggle()
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: bridge.showFullPageInFix ? "crop" : "doc.viewfinder")
                            .font(.system(size: 10, weight: .bold))
                        Text(bridge.showFullPageInFix ? "Measure" : "Full Page")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(SkyTheme.blue700)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(Color.white, in: Capsule())
                    .overlay(Capsule().stroke(SkyTheme.line, lineWidth: 0.8))
                }
                .buttonStyle(PressableButtonStyle())

                Button {
                    withAnimation(fastAnimation) {
                        bridge.isFixPhotoExpanded.toggle()
                    }
                } label: {
                    Image(systemName: bridge.isFixPhotoExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(SkyTheme.navy900)
                        .frame(width: 24, height: 24)
                        .background(Color.white, in: Circle())
                        .overlay(Circle().stroke(SkyTheme.line, lineWidth: 0.8))
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel(bridge.isFixPhotoExpanded ? "Compact Photo Strip" : "Expand Photo Strip")
            }
            .frame(height: 24)

            // Strictly-Sized Original Scan Viewport (never expands beyond photoHeight)
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white)

                if bridge.showFullPageInFix, let fullPageImage {
                    let aspect = max(0.45, fullPageImage.size.width / max(1, fullPageImage.size.height))
                    Image(uiImage: fullPageImage)
                        .resizable()
                        .aspectRatio(aspect, contentMode: .fit)
                        .overlay {
                            GeometryReader { imgGeo in
                                ZStack(alignment: .topLeading) {
                                    ForEach(bridge.allPageBarBoxes) { box in
                                        let isCurrent = (box.barNumber == bridge.activeFlagBarNumber || box.id == bridge.activeFlagBarIndex)
                                        let stroke: Color = isCurrent
                                            ? highlightColor
                                            : (box.level == "bad" ? SkyTheme.wrongInk.opacity(0.55) : SkyTheme.blue600.opacity(0.32))
                                        Button {
                                            bridge.focusBarOnPage(box.id)
                                        } label: {
                                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                                .fill(isCurrent ? highlightColor.opacity(0.18) : Color.clear)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                                        .stroke(stroke, lineWidth: isCurrent ? 2.0 : 0.8)
                                                )
                                        }
                                        .buttonStyle(.plain)
                                        .frame(
                                            width: max(10, imgGeo.size.width * box.rect.width),
                                            height: max(10, imgGeo.size.height * box.rect.height)
                                        )
                                        .offset(
                                            x: imgGeo.size.width * box.rect.x,
                                            y: imgGeo.size.height * box.rect.y
                                        )
                                    }
                                }
                            }
                        }
                        .padding(3)
                } else if let croppedImage {
                    let aspect = max(1.1, croppedImage.size.width / max(1, croppedImage.size.height))
                    Image(uiImage: croppedImage)
                        .resizable()
                        .aspectRatio(aspect, contentMode: .fit)
                        .overlay {
                            if let box = bridge.activeBarInCropRect {
                                GeometryReader { imgGeo in
                                    ZStack(alignment: .topLeading) {
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .fill(highlightColor.opacity(0.10))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                                    .stroke(highlightColor, lineWidth: 1.8)
                                            )
                                            .frame(
                                                width: max(22, imgGeo.size.width * box.width),
                                                height: max(18, imgGeo.size.height * box.height)
                                            )
                                            .offset(
                                                x: imgGeo.size.width * box.x,
                                                y: imgGeo.size.height * box.y
                                            )

                                        Text("Bar \(bridge.activeFlagBarNumber)")
                                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1.5)
                                            .background(highlightColor, in: Capsule())
                                            .offset(
                                                x: max(2, imgGeo.size.width * box.x + 3),
                                                y: max(2, imgGeo.size.height * box.y + 3)
                                            )
                                    }
                                }
                            }
                        }
                        .padding(2)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "photo")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(SkyTheme.slate600)
                        Text("Original scan for Bar \(bridge.activeFlagBarNumber)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(SkyTheme.slate600)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: photoHeight)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isBad ? SkyTheme.wrongInk.opacity(0.38) : SkyTheme.line, lineWidth: 1)
            )

            // Direct Comparison Bridge Header pointing to the Live Editable Score right below
            HStack(spacing: 5) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(SkyTheme.blue600)
                Text("Bar \(bridge.activeFlagBarNumber) · Editable Score")
                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                    .foregroundStyle(SkyTheme.blue700)

                Spacer(minLength: 4)

                Text("Drag notes up/down to change pitch")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SkyTheme.slate600)
                    .lineLimit(1)
            }
            .frame(height: 16)
            .padding(.horizontal, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(height: bridge.isFixPhotoExpanded ? 168 : 128)
        .background(
            SkyTheme.sky50.opacity(0.98)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(SkyTheme.line)
                        .frame(height: 0.75)
                }
        )
    }

    // MARK: - iPhone Single Adaptive Bottom Dock (Play / Fix / Edit)

    private var iPhoneAdaptiveBottomDock: some View {
        VStack(spacing: 8) {
            switch bridge.editorMode {
            case .play:
                iPhonePlayDockContent
            case .fix:
                iPhoneFixDockContent
            case .edit:
                iPhoneEditDockContent
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 9)
        .background(
            SkyTheme.sky25.opacity(0.97)
                .background(.ultraThinMaterial)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(SkyTheme.line.opacity(0.85))
                        .frame(height: 0.75)
                }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    /// Mode A — Play & Practice Dock (Default)
    private var iPhonePlayDockContent: some View {
        HStack(spacing: 8) {
            Button {
                bridge.togglePlay()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: bridge.isPlaying ? "stop.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                    Text(bridge.isPlaying ? "Stop" : "Play")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(
                    bridge.isPlaying ? SkyTheme.navy900 : SkyTheme.blue600,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(bridge.isPlaying ? "Stop Playback" : "Play Score")

            Button {
                withAnimation(fastAnimation) {
                    bridge.setEditorMode(.fix)
                }
            } label: {
                HStack(spacing: 6) {
                    Text("Fix")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(bridge.flaggedCount > 0 ? SkyTheme.wrongInk : SkyTheme.navy900)

                    if bridge.flaggedCount > 0 {
                        Text("\(bridge.flaggedCount)")
                            .font(.system(size: 11, weight: .heavy, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(SkyTheme.wrongInk, in: Capsule())
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(SkyTheme.sureInk)
                    }
                }
                .padding(.horizontal, 13)
                .frame(height: 42)
                .background(
                    bridge.flaggedCount > 0 ? SkyTheme.wrongFill : Color.white,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(bridge.flaggedCount > 0 ? SkyTheme.wrongInk.opacity(0.3) : SkyTheme.line, lineWidth: 1)
                )
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Fix Flagged Bars")

            Button {
                withAnimation(fastAnimation) {
                    bridge.setEditorMode(.edit)
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "slider.horizontal.below.rectangle")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Edit")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                }
                .foregroundStyle(SkyTheme.navy900)
                .padding(.horizontal, 13)
                .frame(height: 42)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(SkyTheme.line, lineWidth: 1)
                )
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Edit Notes")

            Button {
                showTempoPopover.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(bridge.isLoopEnabled ? SkyTheme.blue600 : SkyTheme.navy900)
                    .frame(width: 42, height: 42)
                    .background(
                        bridge.isLoopEnabled ? SkyTheme.sky100 : Color.white,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(SkyTheme.line, lineWidth: 1)
                    )
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Tempo and Practice Options")
            .popover(isPresented: $showTempoPopover) {
                tempoAndLoopPopover
                    .presentationCompactAdaptation(.popover)
            }
        }
    }

    /// Mode B — Fix-It Compare & Inline Edit Dock
    /// Lets the user step through flagged bars, mark them "Looks Right", AND directly drag/edit notes
    /// while the side-by-side original scan photo remains pinned above the live editable score.
    private var iPhoneFixDockContent: some View {
        VStack(spacing: 7) {
            // Row 1: Flagged Bar Stepper + "Looks Right" + Done
            HStack(spacing: 6) {
                Button {
                    bridge.stepFlaggedBar(-1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(SkyTheme.navy900)
                        .frame(width: 32, height: 34)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(SkyTheme.line, lineWidth: 1))
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(bridge.flaggedCount == 0)
                .accessibilityLabel("Previous Flagged Bar")

                if bridge.flaggedCount > 0 {
                    Text("Bar \(bridge.activeFlagBarNumber) (\(bridge.activeFlagPosition)/\(max(1, bridge.activeFlagTotal)))")
                        .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(SkyTheme.navy900)
                        .lineLimit(1)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 12.5))
                            .foregroundStyle(SkyTheme.sureInk)
                        Text("All reviewed")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(SkyTheme.sureInk)
                    }
                }

                Button {
                    bridge.stepFlaggedBar(1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13.5, weight: .bold))
                        .foregroundStyle(SkyTheme.navy900)
                        .frame(width: 32, height: 34)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(SkyTheme.line, lineWidth: 1))
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(bridge.flaggedCount == 0)
                .accessibilityLabel("Next Flagged Bar")

                Spacer(minLength: 2)

                Button {
                    bridge.markCurrentBarLooksRight()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .heavy))
                        Text("Looks Right")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(
                        bridge.flaggedCount > 0 ? SkyTheme.sureInk : SkyTheme.sureInk.opacity(0.45),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(bridge.flaggedCount == 0)

                Button {
                    withAnimation(fastAnimation) {
                        bridge.setEditorMode(.play)
                    }
                } label: {
                    Text("Done")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(SkyTheme.blue600)
                        .padding(.horizontal, 8)
                        .frame(height: 34)
                }
                .buttonStyle(PressableButtonStyle())
            }

            // Row 2: Inline Note & Rhythm Editing Controls (with crisp vector music notation icons)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    // Tool selector: Drag | + Note | Rest
                    HStack(spacing: 2) {
                        ForEach([EditTool.drag, EditTool.note, EditTool.rest]) { tool in
                            let isSelected = (bridge.editTool == tool)
                            Button {
                                bridge.setEditTool(tool)
                            } label: {
                                Text(tool.label)
                                    .font(.system(size: 11.5, weight: .bold, design: .rounded))
                                    .foregroundStyle(isSelected ? SkyTheme.blue700 : SkyTheme.slate600)
                                    .padding(.horizontal, 8)
                                    .frame(height: 28)
                                    .background(
                                        isSelected ? Color.white : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    )
                            }
                            .buttonStyle(PressableButtonStyle())
                        }
                    }
                    .padding(2.5)
                    .background(SkyTheme.sky100, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                    Button {
                        bridge.togglePianoPad()
                    } label: {
                        Image(systemName: "pianokeys")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(bridge.isPianoPadVisible ? .white : SkyTheme.navy900)
                            .frame(width: 34, height: 34)
                            .background(
                                bridge.isPianoPadVisible ? SkyTheme.blue600 : Color.white,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(SkyTheme.line, lineWidth: 1)
                            )
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel("Toggle Piano Keyboard")

                    durationChip(id: "whole", label: "Whole Note")
                    durationChip(id: "half", label: "Half Note")
                    durationChip(id: "quarter", label: "Quarter Note")
                    durationChip(id: "eighth", label: "Eighth Note")
                    durationChip(id: "16th", label: "Sixteenth Note")

                    Button {
                        bridge.toggleDot()
                    } label: {
                        Circle()
                            .fill(bridge.isDotted ? SkyTheme.blue700 : SkyTheme.navy900)
                            .frame(width: 5.5, height: 5.5)
                            .frame(width: 34, height: 34)
                            .background(
                                bridge.isDotted ? SkyTheme.sky100 : Color.white,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(bridge.isDotted ? SkyTheme.blue600 : SkyTheme.line, lineWidth: 1)
                            )
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel("Dotted Note")

                    accidentalChip(alter: 1, symbol: "♯", label: "Sharp")
                    accidentalChip(alter: -1, symbol: "♭", label: "Flat")
                    accidentalChip(alter: 0, symbol: "♮", label: "Natural")

                    Button {
                        bridge.deleteSelected()
                    } label: {
                        Image(systemName: "delete.left")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(SkyTheme.wrongInk)
                            .frame(width: 36, height: 34)
                            .background(SkyTheme.wrongFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(SkyTheme.wrongInk.opacity(0.25), lineWidth: 1)
                            )
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel("Delete Selected Note or Rest")
                }
            }
        }
    }

    /// Mode C — Note & Rhythm Edit Dock
    private var iPhoneEditDockContent: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                HStack(spacing: 3) {
                    ForEach(EditTool.allCases) { tool in
                        let isSelected = (bridge.editTool == tool)
                        Button {
                            bridge.setEditTool(tool)
                        } label: {
                            Text(tool.label)
                                .font(.system(size: 12.5, weight: .bold, design: .rounded))
                                .foregroundStyle(isSelected ? SkyTheme.blue700 : SkyTheme.slate600)
                                .padding(.horizontal, 10)
                                .frame(height: 30)
                                .background(
                                    isSelected ? Color.white : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                        }
                        .buttonStyle(PressableButtonStyle())
                    }
                }
                .padding(3)
                .background(SkyTheme.sky100, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                Button {
                    bridge.togglePianoPad()
                } label: {
                    Image(systemName: "pianokeys")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(bridge.isPianoPadVisible ? .white : SkyTheme.navy900)
                        .frame(width: 34, height: 34)
                        .background(
                            bridge.isPianoPadVisible ? SkyTheme.blue600 : Color.white,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(SkyTheme.line, lineWidth: 1)
                        )
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("Toggle Piano Keyboard")

                Spacer(minLength: 2)

                Button {
                    withAnimation(fastAnimation) {
                        bridge.setEditorMode(.play)
                    }
                } label: {
                    Text("Done")
                        .font(.system(size: 13.5, weight: .bold, design: .rounded))
                        .foregroundStyle(SkyTheme.blue600)
                        .padding(.horizontal, 6)
                        .frame(height: 34)
                }
                .buttonStyle(PressableButtonStyle())
            }

            // Row 2: Duration & Accidental Strip (using vector MusicDurationGlyphView)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    durationChip(id: "whole", label: "Whole Note")
                    durationChip(id: "half", label: "Half Note")
                    durationChip(id: "quarter", label: "Quarter Note")
                    durationChip(id: "eighth", label: "Eighth Note")
                    durationChip(id: "16th", label: "Sixteenth Note")

                    Button {
                        bridge.toggleDot()
                    } label: {
                        Circle()
                            .fill(bridge.isDotted ? SkyTheme.blue700 : SkyTheme.navy900)
                            .frame(width: 5.5, height: 5.5)
                            .frame(width: 36, height: 36)
                            .background(
                                bridge.isDotted ? SkyTheme.sky100 : Color.white,
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(bridge.isDotted ? SkyTheme.blue600 : SkyTheme.line, lineWidth: 1)
                            )
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel("Dotted Note")

                    accidentalChip(alter: 1, symbol: "♯", label: "Sharp")
                    accidentalChip(alter: -1, symbol: "♭", label: "Flat")
                    accidentalChip(alter: 0, symbol: "♮", label: "Natural")

                    Button {
                        bridge.deleteSelected()
                    } label: {
                        Image(systemName: "delete.left")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(SkyTheme.wrongInk)
                            .frame(width: 38, height: 36)
                            .background(SkyTheme.wrongFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(SkyTheme.wrongInk.opacity(0.25), lineWidth: 1)
                            )
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel("Delete Selected Note or Rest")
                }
            }
        }
    }

    private func durationChip(id: String, label: String) -> some View {
        let isSelected = (bridge.activeDuration == id)
        return Button {
            bridge.selectDuration(id)
        } label: {
            MusicDurationGlyphView(
                durationID: id,
                color: isSelected ? SkyTheme.blue700 : SkyTheme.navy900
            )
            .frame(width: 36, height: 34)
            .background(
                isSelected ? SkyTheme.sky100 : Color.white,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? SkyTheme.blue600 : SkyTheme.line, lineWidth: 1)
            )
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
    }

    private func accidentalChip(alter: Int, symbol: String, label: String) -> some View {
        return Button {
            bridge.applyAccidental(alter)
        } label: {
            Text(symbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(SkyTheme.navy900)
                .frame(width: 34, height: 34)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(SkyTheme.line, lineWidth: 1)
                )
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(label)
    }

    private var tempoAndLoopPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Tempo & Practice")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(SkyTheme.navy900)
                Spacer()
                Text("♩ = \(bridge.tempoBPM)")
                    .font(.system(size: 14, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(SkyTheme.blue600)
            }

            HStack(spacing: 10) {
                Button {
                    bridge.setTempo(bridge.tempoBPM - 4)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(SkyTheme.sky50, in: Circle())
                }
                .buttonStyle(.plain)

                Slider(
                    value: Binding(
                        get: { Double(bridge.tempoBPM) },
                        set: { bridge.setTempo(Int($0.rounded())) }
                    ),
                    in: 40...208,
                    step: 1
                )
                .tint(SkyTheme.blue600)

                Button {
                    bridge.setTempo(bridge.tempoBPM + 4)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(SkyTheme.sky50, in: Circle())
                }
                .buttonStyle(.plain)
            }

            Toggle(isOn: Binding(
                get: { bridge.isLoopEnabled },
                set: { _ in bridge.toggleLoop() }
            )) {
                Label("Loop Selected Bars", systemImage: "repeat")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SkyTheme.navy900)
            }
            .tint(SkyTheme.blue600)
        }
        .padding(16)
        .frame(width: 270)
    }

    // MARK: - iPad (.regular): 52pt Unified Studio Top Bar + 3-Region Split Workspace

    private func iPadStudioOverlay(size: CGSize) -> some View {
        let leftWidth: CGFloat = bridge.showiPadPhotoPane ? min(max(size.width * 0.27, 250), 340) : 0
        let rightWidth: CGFloat = min(max(size.width * 0.22, 236), 280)

        return VStack(spacing: 0) {
            iPadStudioTopToolbar

            HStack(spacing: 0) {
                if bridge.showiPadPhotoPane {
                    iPadLeftOriginalScanPane
                        .frame(width: leftWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                // Center region is transparent so the mounted VexFlow EditorWebView shines through
                Spacer(minLength: 0)

                iPadRightInspectorRail
                    .frame(width: rightWidth)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var iPadStudioTopToolbar: some View {
        HStack(spacing: 10) {
            Button {
                bridge.showLibraryHome()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .bold))
                    Text("Scores")
                        .font(.system(size: 14.5, weight: .bold, design: .rounded))
                }
                .foregroundStyle(SkyTheme.blue600)
                .padding(.horizontal, 10)
                .frame(height: 36)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(SkyTheme.line, lineWidth: 1))
            }
            .buttonStyle(PressableButtonStyle())

            Button {
                withAnimation(fastAnimation) {
                    bridge.showiPadPhotoPane.toggle()
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(bridge.showiPadPhotoPane ? SkyTheme.blue600 : SkyTheme.slate600)
                    .frame(width: 36, height: 36)
                    .background(
                        bridge.showiPadPhotoPane ? SkyTheme.sky100 : Color.white,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(SkyTheme.line, lineWidth: 1))
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Toggle Original Scan Sidebar")

            titleDropdownMenu

            Button {
                bridge.openPagesSheet()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Page \(bridge.activePageIndex + 1) of \(bridge.pageCount)")
                        .font(.system(size: 12.5, weight: .bold, design: .rounded).monospacedDigit())
                }
                .foregroundStyle(SkyTheme.blue700)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(SkyTheme.sky100, in: Capsule())
            }
            .buttonStyle(PressableButtonStyle())

            Spacer(minLength: 8)

            // Center Mode Switcher: Drag Notes | + Add | Rest | Apple Pencil Ink
            HStack(spacing: 4) {
                ForEach(EditTool.allCases) { tool in
                    let isSelected = (bridge.editTool == tool)
                    Button {
                        bridge.setEditTool(tool)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: tool.systemImage)
                                .font(.system(size: 12, weight: .semibold))
                            Text(tool.iPadLabel)
                                .font(.system(size: 12.5, weight: .bold, design: .rounded))
                        }
                        .foregroundStyle(isSelected ? SkyTheme.blue700 : SkyTheme.slate600)
                        .padding(.horizontal, 11)
                        .frame(height: 30)
                        .background(
                            isSelected ? Color.white : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }
            .padding(3)
            .background(SkyTheme.sky100, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

            Spacer(minLength: 8)

            // Right Transport & Export
            HStack(spacing: 7) {
                Button {
                    bridge.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(bridge.canUndo ? SkyTheme.navy900 : SkyTheme.slate600.opacity(0.38))
                        .frame(width: 34, height: 34)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(SkyTheme.line, lineWidth: 1))
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(!bridge.canUndo)
                .accessibilityLabel("Undo")

                Button {
                    bridge.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(bridge.canRedo ? SkyTheme.navy900 : SkyTheme.slate600.opacity(0.38))
                        .frame(width: 34, height: 34)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(SkyTheme.line, lineWidth: 1))
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(!bridge.canRedo)
                .accessibilityLabel("Redo")

                Button {
                    bridge.togglePlay()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: bridge.isPlaying ? "stop.fill" : "play.fill")
                            .font(.system(size: 13, weight: .bold))
                        Text(bridge.isPlaying ? "Stop" : "Play")
                            .font(.system(size: 13.5, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(
                        bridge.isPlaying ? SkyTheme.navy900 : SkyTheme.blue600,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                }
                .buttonStyle(PressableButtonStyle())

                Button {
                    showTempoPopover.toggle()
                } label: {
                    Text("♩=\(bridge.tempoBPM)")
                        .font(.system(size: 12.5, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(SkyTheme.navy900)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(SkyTheme.line, lineWidth: 1))
                }
                .buttonStyle(PressableButtonStyle())
                .popover(isPresented: $showTempoPopover) {
                    tempoAndLoopPopover
                        .presentationCompactAdaptation(.popover)
                }

                exportMenuButton(compact: false)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(
            SkyTheme.sky25.opacity(0.96)
                .background(.ultraThinMaterial)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(SkyTheme.line)
                        .frame(height: 0.75)
                }
        )
    }

    /// Region 1 (Left, ~28% width): Synchronized Original Scan Pane with live interactive bar highlight boxes.
    private var iPadLeftOriginalScanPane: some View {
        let pageImage = store.pageImage(
            for: bridge.activeScoreID,
            pageIndex: bridge.activePageIndex,
            jobID: bridge.activePageJobID
        )

        return VStack(spacing: 0) {
            HStack {
                Text("Original Scan · Page \(bridge.activePageIndex + 1)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(SkyTheme.navy900)

                Spacer()

                Button {
                    bridge.adjustPageEdges()
                } label: {
                    Text("Edges")
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                        .foregroundStyle(SkyTheme.navy900)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(SkyTheme.line, lineWidth: 1))
                }
                .buttonStyle(PressableButtonStyle())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(SkyTheme.sky50)
            .overlay(alignment: .bottom) {
                Rectangle().fill(SkyTheme.line).frame(height: 0.75)
            }

            ScrollView {
                VStack(spacing: 12) {
                    if let pageImage {
                        let aspect = max(0.4, pageImage.size.width / max(1, pageImage.size.height))
                        Image(uiImage: pageImage)
                            .resizable()
                            .aspectRatio(aspect, contentMode: .fit)
                            .overlay {
                                GeometryReader { imgGeo in
                                    ZStack(alignment: .topLeading) {
                                        ForEach(bridge.allPageBarBoxes) { box in
                                            let isSelected = (box.id == bridge.currentBarIndex)
                                            let strokeColor: Color = isSelected
                                                ? SkyTheme.blue600
                                                : (box.level == "bad" ? SkyTheme.wrongInk : (box.level == "check" ? SkyTheme.marigold : SkyTheme.sureInk.opacity(0.35)))
                                            let fillColor: Color = isSelected
                                                ? SkyTheme.blue600.opacity(0.16)
                                                : (box.level == "bad" ? SkyTheme.wrongInk.opacity(0.14) : (box.level == "check" ? SkyTheme.marigold.opacity(0.12) : Color.clear))

                                            Button {
                                                bridge.focusBarOnPage(box.id)
                                            } label: {
                                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                                    .fill(fillColor)
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                                                            .stroke(strokeColor, lineWidth: isSelected ? 2.2 : (box.level == "ok" ? 0.6 : 1.5))
                                                    )
                                            }
                                            .buttonStyle(.plain)
                                            .frame(
                                                width: max(12, imgGeo.size.width * box.rect.width),
                                                height: max(12, imgGeo.size.height * box.rect.height)
                                            )
                                            .offset(
                                                x: imgGeo.size.width * box.rect.x,
                                                y: imgGeo.size.height * box.rect.y
                                            )
                                        }
                                    }
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(SkyTheme.line, lineWidth: 1)
                            )
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "doc.viewfinder")
                                .font(.system(size: 28))
                                .foregroundStyle(SkyTheme.slate600.opacity(0.6))
                            Text("Original scan photo appears here when a camera or photo page is open.")
                                .font(.system(size: 12.5))
                                .foregroundStyle(SkyTheme.slate600)
                                .multilineTextAlignment(.center)
                        }
                        .padding(24)
                        .frame(maxWidth: .infinity)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(SkyTheme.line, lineWidth: 1))
                    }
                }
                .padding(12)
            }
        }
        .background(SkyTheme.sky50.opacity(0.95))
        .overlay(alignment: .trailing) {
            Rectangle().fill(SkyTheme.line).frame(width: 0.75)
        }
    }

    /// Region 3 (Right, ~22% width): Always-On Fix It Queue + Duration & Pitch Palette
    private var iPadRightInspectorRail: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                // Card 1: Always-On Fix It Queue
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Fix Queue")
                            .font(.system(size: 12.5, weight: .bold, design: .rounded))
                            .foregroundStyle(SkyTheme.navy900)

                        Spacer()

                        if bridge.flaggedCount > 0 {
                            Text("\(bridge.flaggedCount) left")
                                .font(.system(size: 11, weight: .heavy, design: .rounded).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(SkyTheme.wrongInk, in: Capsule())
                        } else {
                            Text("All clear")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(SkyTheme.sureInk)
                        }
                    }

                    if bridge.flaggedCount > 0 {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Bar \(bridge.activeFlagBarNumber) · \(bridge.activeFlagReason.isEmpty ? "Check rhythm" : bridge.activeFlagReason)")
                                .font(.system(size: 12.5, weight: .bold, design: .rounded))
                                .foregroundStyle(SkyTheme.navy900)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack(spacing: 6) {
                                Button {
                                    bridge.stepFlaggedBar(-1)
                                } label: {
                                    Image(systemName: "chevron.left")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(SkyTheme.navy900)
                                        .frame(width: 30, height: 32)
                                        .background(SkyTheme.sky50, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(SkyTheme.line, lineWidth: 1))
                                }
                                .buttonStyle(PressableButtonStyle())

                                Button {
                                    bridge.markCurrentBarLooksRight()
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 11, weight: .heavy))
                                        Text("OK")
                                            .font(.system(size: 12.5, weight: .bold, design: .rounded))
                                    }
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 32)
                                    .background(SkyTheme.sureInk, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                                .buttonStyle(PressableButtonStyle())

                                Button {
                                    bridge.stepFlaggedBar(1)
                                } label: {
                                    HStack(spacing: 3) {
                                        Text("Next")
                                            .font(.system(size: 12, weight: .bold, design: .rounded))
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 10.5, weight: .bold))
                                    }
                                    .foregroundStyle(SkyTheme.navy900)
                                    .padding(.horizontal, 9)
                                    .frame(height: 32)
                                    .background(SkyTheme.sky50, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(SkyTheme.line, lineWidth: 1))
                                }
                                .buttonStyle(PressableButtonStyle())
                            }
                        }
                        .padding(10)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(SkyTheme.wrongInk.opacity(0.28), lineWidth: 1)
                        )
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(SkyTheme.sureInk)
                            Text("Every bar has been verified.")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(SkyTheme.sureInk)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                }
                .padding(12)
                .background(
                    bridge.flaggedCount > 0 ? SkyTheme.wrongFill : SkyTheme.sureFill,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(bridge.flaggedCount > 0 ? SkyTheme.wrongInk.opacity(0.22) : SkyTheme.sureInk.opacity(0.22), lineWidth: 1)
                )

                // Card 2: Duration & Pitch Palette
                VStack(alignment: .leading, spacing: 10) {
                    Text("Duration & Pitch")
                        .font(.system(size: 12.5, weight: .bold, design: .rounded))
                        .foregroundStyle(SkyTheme.navy900)

                    let cols = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)
                    LazyVGrid(columns: cols, spacing: 6) {
                        durationChip(id: "whole", label: "Whole Note")
                        durationChip(id: "half", label: "Half Note")
                        durationChip(id: "quarter", label: "Quarter Note")
                        durationChip(id: "eighth", label: "Eighth Note")

                        durationChip(id: "16th", label: "Sixteenth Note")
                        accidentalChip(alter: 1, symbol: "♯", label: "Sharp")
                        accidentalChip(alter: -1, symbol: "♭", label: "Flat")
                        accidentalChip(alter: 0, symbol: "♮", label: "Natural")
                    }

                    HStack(spacing: 6) {
                        Button {
                            bridge.toggleDot()
                        } label: {
                            Text("Dot ·")
                                .font(.system(size: 12.5, weight: .bold, design: .rounded))
                                .foregroundStyle(bridge.isDotted ? SkyTheme.blue700 : SkyTheme.navy900)
                                .frame(maxWidth: .infinity)
                                .frame(height: 34)
                                .background(
                                    bridge.isDotted ? SkyTheme.sky100 : Color.white,
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                                )
                                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(SkyTheme.line, lineWidth: 1))
                        }
                        .buttonStyle(PressableButtonStyle())

                        Button {
                            bridge.triggerRest()
                        } label: {
                            Text("Rest")
                                .font(.system(size: 12.5, weight: .bold, design: .rounded))
                                .foregroundStyle(SkyTheme.navy900)
                                .frame(maxWidth: .infinity)
                                .frame(height: 34)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(SkyTheme.line, lineWidth: 1))
                        }
                        .buttonStyle(PressableButtonStyle())

                        Button {
                            bridge.deleteSelected()
                        } label: {
                            Image(systemName: "delete.left")
                                .font(.system(size: 13.5, weight: .bold))
                                .foregroundStyle(SkyTheme.wrongInk)
                                .frame(width: 40, height: 34)
                                .background(SkyTheme.wrongFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        .buttonStyle(PressableButtonStyle())
                    }
                }
                .padding(12)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(SkyTheme.line, lineWidth: 1))

                // Card 3: Quick Studio Tools
                VStack(alignment: .leading, spacing: 8) {
                    Text("Studio Tools")
                        .font(.system(size: 12.5, weight: .bold, design: .rounded))
                        .foregroundStyle(SkyTheme.navy900)

                    Button {
                        bridge.togglePianoPad()
                    } label: {
                        HStack {
                            Label("2-Octave Piano Pad", systemImage: "pianokeys")
                                .font(.system(size: 12.5, weight: .bold, design: .rounded))
                            Spacer()
                            Text(bridge.isPianoPadVisible ? "On" : "Off")
                                .font(.system(size: 11.5, weight: .bold))
                                .foregroundStyle(bridge.isPianoPadVisible ? SkyTheme.blue600 : SkyTheme.slate600)
                        }
                        .foregroundStyle(SkyTheme.navy900)
                        .padding(.horizontal, 10)
                        .frame(height: 36)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(SkyTheme.line, lineWidth: 1))
                    }
                    .buttonStyle(PressableButtonStyle())

                    Button {
                        bridge.openKeyTimeTranspose()
                    } label: {
                        HStack {
                            Label("Key, Time & Transpose", systemImage: "tuningfork")
                                .font(.system(size: 12.5, weight: .bold, design: .rounded))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(SkyTheme.slate600)
                        }
                        .foregroundStyle(SkyTheme.navy900)
                        .padding(.horizontal, 10)
                        .frame(height: 36)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(SkyTheme.line, lineWidth: 1))
                    }
                    .buttonStyle(PressableButtonStyle())
                }
                .padding(12)
                .background(SkyTheme.sky50, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(SkyTheme.line, lineWidth: 1))
            }
            .padding(12)
        }
        .background(SkyTheme.sky50.opacity(0.96))
        .overlay(alignment: .leading) {
            Rectangle().fill(SkyTheme.line).frame(width: 0.75)
        }
    }
}

// MARK: - Local-First Native ScoreLibraryView (Your Music)

/// Native SwiftUI library grid reading directly from `LocalScoreStore.shared` (`Application Support/MusicScan/Scores/`).
/// Features clean humanized titles (`Scan · Nov 28` or work title), status badges (`Ready to play` / `N bars to check`),
/// and native iOS `.contextMenu` (`Rename`, `Export MusicXML`, `Export MIDI`, `Delete`) with zero floating `×` buttons.
struct ScoreLibraryView: View {
    let isPro: Bool
    @Bindable var bridge: MusicScanBridgeController
    var store = LocalScoreStore.shared
    let onGoToScan: () -> Void
    let onOpenGuide: () -> Void
    let onOpenSettings: () -> Void

    private enum LibraryFilter: String, CaseIterable {
        case all = "All"
        case toCheck = "To Check"
    }

    @State private var filter: LibraryFilter = .all
    @State private var itemToRename: LocalScoreItem?
    @State private var renameText = ""

    private var filteredScores: [LocalScoreItem] {
        switch filter {
        case .all:
            return store.scores
        case .toCheck:
            return store.scores.filter { $0.flaggedBarsCount > 0 }
        }
    }

    private var toCheckCount: Int {
        store.scores.filter { $0.flaggedBarsCount > 0 }.count
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let scale = min(max(width / 390.0, 0.90), 1.24)
            let isShort = height < 660
            let horizontalPad: CGFloat = width < 380 ? 18 : (width < 600 ? 24 : 36)
            let contentMaxWidth: CGFloat = width >= 720 ? 780 : 560
            let columns = Array(
                repeating: GridItem(.flexible(), spacing: 14),
                count: width >= 680 ? 3 : 2
            )

            ZStack {
                SkyDitheredCanvas()
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        SkyWorkspaceHeader(
                            title: "Your Music",
                            isPro: isPro,
                            compact: width < 380,
                            scale: scale,
                            onOpenGuide: onOpenGuide,
                            onOpenSettings: onOpenSettings
                        )

                        filterBar

                        if filteredScores.isEmpty {
                            emptyFilterCard
                        } else {
                            LazyVGrid(columns: columns, spacing: 14) {
                                ForEach(filteredScores) { item in
                                    scoreCard(for: item)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, horizontalPad)
                    .padding(.top, isShort ? 10 : 18)
                    .padding(.bottom, 28)
                    .frame(maxWidth: contentMaxWidth, alignment: .topLeading)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .alert(
            "Rename Score",
            isPresented: Binding(
                get: { itemToRename != nil },
                set: { if !$0 { itemToRename = nil } }
            )
        ) {
            TextField("Score title", text: $renameText)
            Button("Cancel", role: .cancel) {
                itemToRename = nil
            }
            Button("Save") {
                if let item = itemToRename {
                    bridge.renameLocalScore(item, to: renameText)
                }
                itemToRename = nil
            }
        } message: {
            Text("Enter a clean title for this score.")
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            filterPill(.all, count: store.scores.count)
            filterPill(.toCheck, count: toCheckCount)
            Spacer()
            Button(action: onGoToScan) {
                Label("New Scan", systemImage: "plus")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(SkyTheme.blue700)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(SkyTheme.sky100, in: Capsule())
            }
            .buttonStyle(PressableButtonStyle())
        }
    }

    private func filterPill(_ tab: LibraryFilter, count: Int) -> some View {
        let isSelected = (filter == tab)
        return Button {
            withAnimation(.easeOut(duration: 0.18)) {
                filter = tab
            }
        } label: {
            HStack(spacing: 6) {
                Text(tab.rawValue)
                    .font(.system(size: 13.5, weight: .bold, design: .rounded))
                Text("\(count)")
                    .font(.system(size: 11.5, weight: .heavy, design: .rounded).monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        isSelected ? Color.white.opacity(0.24) : SkyTheme.sky100,
                        in: Capsule()
                    )
            }
            .foregroundStyle(isSelected ? .white : SkyTheme.navy900)
            .padding(.horizontal, 13)
            .frame(height: 34)
            .background(
                isSelected ? SkyTheme.blue600 : Color.white,
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .stroke(isSelected ? Color.clear : SkyTheme.line, lineWidth: 1)
            )
        }
        .buttonStyle(PressableButtonStyle())
    }

    private func scoreCard(for item: LocalScoreItem) -> some View {
        let thumb = store.thumbnailImage(for: item.id, jobID: item.primaryJobID)
        let needsCheck = item.flaggedBarsCount > 0

        return Button {
            bridge.openLocalScore(item)
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(SkyTheme.sky50)

                    if let thumb {
                        Image(uiImage: thumb)
                            .resizable()
                            .scaledToFill()
                            .frame(height: 108)
                            .frame(maxWidth: .infinity)
                            .clipped()
                    } else {
                        StaffLinesBackdrop(lineSpacing: 10)
                            .opacity(0.55)
                            .overlay {
                                Image(systemName: "music.quarternote.3")
                                    .font(.system(size: 26, weight: .semibold))
                                    .foregroundStyle(SkyTheme.blue600.opacity(0.6))
                            }
                    }
                }
                .frame(height: 108)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(SkyTheme.line.opacity(0.8), lineWidth: 0.8)
                )

                Text(item.cleanTitle)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(SkyTheme.navy900)
                    .lineLimit(1)

                Text(metaSubtitle(for: item))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(SkyTheme.slate600)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Circle()
                        .fill(needsCheck ? SkyTheme.wrongInk : SkyTheme.sureInk)
                        .frame(width: 6, height: 6)
                    Text(item.statusLabel)
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                        .foregroundStyle(needsCheck ? SkyTheme.wrongInk : SkyTheme.sureInk)
                        .lineLimit(1)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    needsCheck ? SkyTheme.wrongFill : SkyTheme.sureFill,
                    in: Capsule()
                )
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .engravedCard(cornerRadius: 18)
        }
        .buttonStyle(PressableButtonStyle())
        .contextMenu {
            Button {
                bridge.openLocalScore(item)
            } label: {
                Label("Open Score", systemImage: "music.note.list")
            }

            Button {
                renameText = item.cleanTitle
                itemToRename = item
            } label: {
                Label("Rename…", systemImage: "pencil")
            }

            Divider()

            Button {
                bridge.exportLocalScore(item, format: "xml")
            } label: {
                Label("Export MusicXML (.musicxml)", systemImage: "doc.text")
            }

            Button {
                bridge.exportLocalScore(item, format: "mid")
            } label: {
                Label("Export MIDI (.mid)", systemImage: "pianokeys")
            }

            Divider()

            Button(role: .destructive) {
                bridge.deleteLocalScore(item)
            } label: {
                Label("Delete Score", systemImage: "trash")
            }
        }
    }

    private func metaSubtitle(for item: LocalScoreItem) -> String {
        var parts: [String] = ["\(max(1, item.barsCount)) bars"]
        if item.pageCount > 1 {
            parts.append("\(item.pageCount) pages")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        parts.append(formatter.localizedString(for: item.updatedAt, relativeTo: Date()))
        return parts.joined(separator: " · ")
    }

    private var emptyFilterCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 28))
                .foregroundStyle(SkyTheme.sureInk)
            Text("Nothing to check")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(SkyTheme.navy900)
            Text("Every saved score is ready to play.")
                .font(.system(size: 13.5))
                .foregroundStyle(SkyTheme.slate600)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
        .engravedCard(cornerRadius: 20)
    }
}

// MARK: - Rich Native OMR Reading Progress UI (stage == .reading)

/// Full-screen native SwiftUI OMR progress overlay displayed while the sheet music is being transcribed.
/// Note: Intentionally omits any mid-scan mode toggle so users cannot toggle Fast/2-Pass while a scan is in flight.
struct NativeReadingProgressView: View {
    @Bindable var bridge: MusicScanBridgeController
    var store = LocalScoreStore.shared

    @State private var scanBeamPhase: CGFloat = 0.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
            readingProgressContent(now: timeline.date)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2.1).repeatForever(autoreverses: true)) {
                scanBeamPhase = 1.0
            }
        }
    }

    @ViewBuilder
    private func readingProgressContent(now: Date) -> some View {
        let elapsed = max(0.1, now.timeIntervalSince(bridge.readingStartedAt ?? now))
        let expectedTotal: Double = bridge.fastMode ? 7.5 : 17.5
        let computedPct = min(0.96, max(bridge.readingProgressFraction, 0.08 + 0.88 * (1.0 - exp(-elapsed / (expectedTotal * 0.72)))))
        let activeStage = resolvedPipelineStage(elapsed: elapsed)

        ZStack {
            SkyDitheredCanvas()
                .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    // Top Status Pill + Live Timer (read-only during active scan)
                    HStack(spacing: 8) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(SkyTheme.blue600)
                                .frame(width: 7, height: 7)
                            Text(bridge.readingBatchText.isEmpty ? "Reading Sheet Music" : bridge.readingBatchText)
                                .font(.system(size: 12.5, weight: .bold, design: .rounded))
                                .foregroundStyle(SkyTheme.blue700)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(SkyTheme.sky100, in: Capsule())

                        Spacer()

                        HStack(spacing: 4) {
                            Image(systemName: "timer")
                                .font(.system(size: 11.5, weight: .bold))
                            Text(String(format: "%.1fs", elapsed))
                                .font(.system(size: 13, weight: .heavy, design: .rounded).monospacedDigit())
                        }
                        .foregroundStyle(SkyTheme.navy900)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white, in: Capsule())
                        .overlay(Capsule().stroke(SkyTheme.line, lineWidth: 1))
                    }

                    // Upright Sheet-Music Preview with Animated Optical Scanner Beam
                    opticalScanPreviewCard(progress: computedPct)

                    // Title + Animated Progress Bar + Sub-stage caption
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(stageHeadline(for: activeStage))
                                .font(.system(size: 18, weight: .heavy, design: .rounded))
                                .foregroundStyle(SkyTheme.navy900)

                            Spacer()

                            Text("\(Int(round(computedPct * 100)))%")
                                .font(.system(size: 14.5, weight: .heavy, design: .rounded).monospacedDigit())
                                .foregroundStyle(SkyTheme.blue600)
                        }

                        GeometryReader { barGeo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(SkyTheme.sky100)
                                    .frame(height: 8)

                                Capsule()
                                    .fill(SkyTheme.blue600)
                                    .frame(width: max(18, barGeo.size.width * computedPct), height: 8)
                                    .animation(.easeOut(duration: 0.22), value: computedPct)
                            }
                        }
                        .frame(height: 8)

                        HStack {
                            Text(stageSubheadline(for: activeStage))
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(SkyTheme.slate600)
                            Spacer()
                            if let prepMs = bridge.lastPrepDurationMs {
                                Text("Upright in \(prepMs) ms")
                                    .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                                    .foregroundStyle(SkyTheme.sureInk)
                            }
                        }
                    }

                    // 4-Stage Pipeline Breakdown Checklist
                    VStack(spacing: 8) {
                        pipelineRow(
                            index: 0,
                            currentStage: activeStage,
                            title: "1. Upright rotation & contrast normalization",
                            detail: bridge.lastPrepDurationMs.map { "\($0) ms on-device" } ?? "Vision CoreML"
                        )
                        pipelineRow(
                            index: 1,
                            currentStage: activeStage,
                            title: "2. Detecting staff lines, clefs & barlines",
                            detail: "Page geometry & system layout"
                        )
                        pipelineRow(
                            index: 2,
                            currentStage: activeStage,
                            title: "3. Reading noteheads, stems, beams & rests",
                            detail: "GPU optical music transformer"
                        )
                        pipelineRow(
                            index: 3,
                            currentStage: activeStage,
                            title: bridge.fastMode
                                ? "4. Building playable MusicXML"
                                : "4. Second-opinion rhythm & beat verification",
                            detail: bridge.fastMode ? "Single-pass mode" : "Flags uncertain bars for Fix mode"
                        )
                    }
                    .padding(12)
                    .background(SkyTheme.sky50, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(SkyTheme.line, lineWidth: 1))
                }
                .padding(18)
                .frame(maxWidth: 500)
                .engravedCard(cornerRadius: 24)
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func opticalScanPreviewCard(progress: Double) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white)

            if let preview = store.latestPreviewImage {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 176)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(8)
            } else {
                StaffLinesBackdrop(lineSpacing: 11)
                    .frame(height: 150)
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "doc.text.viewfinder")
                                .font(.system(size: 30, weight: .semibold))
                                .foregroundStyle(SkyTheme.blue600)
                            Text(bridge.documentTitle.isEmpty ? "Reading sheet music…" : bridge.documentTitle)
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(SkyTheme.navy900)
                        }
                    }
            }

            // Animated horizontal optical scan beam sweeping across the upright page
            GeometryReader { geo in
                let yPos = 14 + (geo.size.height - 28) * scanBeamPhase
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [
                            SkyTheme.blue600.opacity(0.0),
                            SkyTheme.blue600.opacity(0.22),
                            SkyTheme.blue600.opacity(0.85)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 18)

                    Rectangle()
                        .fill(SkyTheme.blue600)
                        .frame(height: 2.5)
                        .shadow(color: SkyTheme.blue600.opacity(0.75), radius: 6, y: 0)
                }
                .offset(y: yPos - 18)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .allowsHitTesting(false)
        }
        .frame(height: 186)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(SkyTheme.sky200, lineWidth: 1.2)
        )
    }

    private func resolvedPipelineStage(elapsed: Double) -> Int {
        if bridge.readingStepIndex >= 3 { return 3 }
        if elapsed < 1.3 { return 0 }
        if elapsed < 4.5 { return max(1, bridge.readingStepIndex) }
        if elapsed < (bridge.fastMode ? 6.5 : 11.5) { return max(2, bridge.readingStepIndex) }
        return 3
    }

    private func stageHeadline(for stage: Int) -> String {
        switch stage {
        case 0: return "Preparing & aligning page…"
        case 1: return "Finding staves, clefs & barlines…"
        case 2: return "Reading notes, chords & rhythms…"
        default:
            return bridge.fastMode
                ? "Assembling playable score…"
                : "Double-checking tricky bars…"
        }
    }

    private func stageSubheadline(for stage: Int) -> String {
        switch stage {
        case 0: return "Rotated upright & enhanced staff contrast on-device"
        case 1: return "Mapping grand-staff systems and measure bounding boxes"
        case 2: return "Transcribing voices, accidentals, beams & tuplets on GPU"
        default:
            return bridge.fastMode
                ? "Generating VexFlow notation & FluidR3 audio voices"
                : "Comparing 2nd pass so uncertain bars are highlighted in Fix mode"
        }
    }

    private func pipelineRow(index: Int, currentStage: Int, title: String, detail: String) -> some View {
        let isDone = index < currentStage
        let isActive = index == currentStage

        return HStack(spacing: 10) {
            ZStack {
                if isDone {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(SkyTheme.sureInk)
                } else if isActive {
                    ProgressView()
                        .controlSize(.small)
                        .tint(SkyTheme.blue600)
                } else {
                    Circle()
                        .stroke(SkyTheme.slate600.opacity(0.35), lineWidth: 1.5)
                        .frame(width: 15, height: 15)
                }
            }
            .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1.5) {
                Text(title)
                    .font(.system(size: 12.5, weight: isActive || isDone ? .bold : .semibold, design: .rounded))
                    .foregroundStyle(isDone ? SkyTheme.navy900 : (isActive ? SkyTheme.blue700 : SkyTheme.slate600))
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SkyTheme.slate600)
            }

            Spacer()

            if isDone {
                Text("Done")
                    .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                    .foregroundStyle(SkyTheme.sureInk)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(SkyTheme.sureFill, in: Capsule())
            } else if isActive {
                Text("Active")
                    .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                    .foregroundStyle(SkyTheme.blue700)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(SkyTheme.sky100, in: Capsule())
            }
        }
        .padding(.vertical, 2)
    }
}
