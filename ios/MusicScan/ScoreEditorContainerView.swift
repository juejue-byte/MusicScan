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
/// - **iPhone (`.compact`)**: Single 44pt top nav bar, contextual inline cropped photo strip in `Fix` mode,
///   full-bleed VexFlow score canvas (~78% height), and single adaptive 3-mode bottom dock (`Play` / `Fix` / `Edit`).
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

    private var springAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.88)
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
            .animation(springAnimation, value: bridge.editorMode)
            .animation(springAnimation, value: bridge.showiPadPhotoPane)
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

    // MARK: - iPhone (.compact): Single 44pt Top Bar + Contextual Fix Strip + Adaptive Bottom Dock

    private func iPhoneCompactOverlay(size: CGSize) -> some View {
        VStack(spacing: 0) {
            iPhoneTopNavigationBar

            if bridge.editorMode == .fix {
                iPhoneFixItPhotoCompareStrip
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Center pass-through viewport where the full-bleed VexFlow score canvas lives
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
            SkyTheme.sky25.opacity(0.95)
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
            .background(Color.white.opacity(0.85), in: Capsule())
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

    /// Shown directly below the 44pt top bar ONLY when `Fix` mode is active on iPhone.
    private var iPhoneFixItPhotoCompareStrip: some View {
        let croppedImage = store.croppedBarImage(
            for: bridge.activeScoreID,
            pageIndex: bridge.activePageIndex,
            jobID: bridge.activePageJobID,
            cropRect: bridge.activeBarCropRect
        )
        let isBad = (bridge.activeFlagLevel == "bad")

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(isBad ? SkyTheme.wrongInk : SkyTheme.marigold)
                        .frame(width: 7, height: 7)
                    Text("ORIG PHOTO · BAR \(bridge.activeFlagBarNumber)")
                        .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                        .tracking(0.5)
                        .foregroundStyle(isBad ? SkyTheme.wrongInk : SkyTheme.navy900)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    (isBad ? SkyTheme.wrongFill : SkyTheme.glanceFill),
                    in: Capsule()
                )

                Text(bridge.activeFlagReason.isEmpty ? "Check notes against your photo" : bridge.activeFlagReason)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(SkyTheme.slate600)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Button {
                    bridge.rescanActiveBar()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10.5, weight: .bold))
                        Text("Rescan")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(SkyTheme.blue700)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(SkyTheme.sky50, in: Capsule())
                    .overlay(Capsule().stroke(SkyTheme.sky200, lineWidth: 0.8))
                }
                .buttonStyle(PressableButtonStyle())
            }

            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white)

                if let croppedImage {
                    Image(uiImage: croppedImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .frame(height: 58)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(3)
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "photo")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(SkyTheme.slate600)
                        Text("Comparing Bar \(bridge.activeFlagBarNumber) on canvas below")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(SkyTheme.slate600)
                    }
                    .frame(height: 44)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isBad ? SkyTheme.wrongInk.opacity(0.45) : SkyTheme.line, lineWidth: 1.2)
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            SkyTheme.sky50.opacity(0.96)
                .background(.ultraThinMaterial)
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
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(
            SkyTheme.sky25.opacity(0.96)
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
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                )
                .shadow(color: SkyTheme.blue600.opacity(0.22), radius: 8, y: 3)
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(bridge.isPlaying ? "Stop Playback" : "Play Score")

            Button {
                withAnimation(springAnimation) {
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
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(bridge.flaggedCount > 0 ? SkyTheme.wrongInk.opacity(0.3) : SkyTheme.line, lineWidth: 1)
                )
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Fix Flagged Bars")

            Button {
                withAnimation(springAnimation) {
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
                .background(Color.white, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
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
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
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

    /// Mode B — Fix-It Stepper Dock
    private var iPhoneFixDockContent: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    bridge.stepFlaggedBar(-1)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(SkyTheme.navy900)
                        .frame(width: 34, height: 34)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(SkyTheme.line, lineWidth: 1))
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(bridge.flaggedCount == 0)
                .accessibilityLabel("Previous Flagged Bar")

                Spacer(minLength: 4)

                if bridge.flaggedCount > 0 {
                    Text("Bar \(bridge.activeFlagBarNumber) (\(bridge.activeFlagPosition) of \(max(1, bridge.activeFlagTotal)))")
                        .font(.system(size: 13.5, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(SkyTheme.navy900)
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(SkyTheme.sureInk)
                        Text("All bars reviewed")
                            .font(.system(size: 13.5, weight: .bold, design: .rounded))
                            .foregroundStyle(SkyTheme.sureInk)
                    }
                }

                Spacer(minLength: 4)

                Button {
                    bridge.stepFlaggedBar(1)
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(SkyTheme.navy900)
                        .frame(width: 34, height: 34)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(SkyTheme.line, lineWidth: 1))
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(bridge.flaggedCount == 0)
                .accessibilityLabel("Next Flagged Bar")

                Button {
                    withAnimation(springAnimation) {
                        bridge.setEditorMode(.play)
                    }
                } label: {
                    Text("Done")
                        .font(.system(size: 13.5, weight: .bold, design: .rounded))
                        .foregroundStyle(SkyTheme.blue600)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                }
                .buttonStyle(PressableButtonStyle())
            }

            HStack(spacing: 8) {
                Button {
                    bridge.markCurrentBarLooksRight()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .heavy))
                        Text("Looks Right")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(
                        bridge.flaggedCount > 0 ? SkyTheme.sureInk : SkyTheme.sureInk.opacity(0.45),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(bridge.flaggedCount == 0)

                Button {
                    withAnimation(springAnimation) {
                        bridge.setEditorMode(.edit)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "pencil")
                            .font(.system(size: 13, weight: .bold))
                        Text("Edit Notes")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(SkyTheme.navy900)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(SkyTheme.line, lineWidth: 1)
                    )
                }
                .buttonStyle(PressableButtonStyle())
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
                                .shadow(color: isSelected ? SkyTheme.navy900.opacity(0.08) : .clear, radius: 3, y: 1)
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
                    withAnimation(springAnimation) {
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

            // Row 2: Duration & Accidental Strip
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    durationChip(id: "whole", symbol: "𝅝", label: "Whole")
                    durationChip(id: "half", symbol: "𝅗𝅥", label: "Half")
                    durationChip(id: "quarter", symbol: "♩", label: "Quarter")
                    durationChip(id: "eighth", symbol: "♪", label: "Eighth")
                    durationChip(id: "16th", symbol: "𝅘𝅥𝅯", label: "16th")

                    Button {
                        bridge.toggleDot()
                    } label: {
                        Text("·")
                            .font(.system(size: 20, weight: .black))
                            .foregroundStyle(bridge.isDotted ? SkyTheme.blue700 : SkyTheme.navy900)
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

    private func durationChip(id: String, symbol: String, label: String) -> some View {
        let isSelected = (bridge.activeDuration == id)
        return Button {
            bridge.selectDuration(id)
        } label: {
            Text(symbol)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(isSelected ? SkyTheme.blue700 : SkyTheme.navy900)
                .frame(width: 38, height: 36)
                .background(
                    isSelected ? SkyTheme.sky100 : Color.white,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
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
                .frame(width: 36, height: 36)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
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
                withAnimation(springAnimation) {
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
                        .shadow(color: isSelected ? SkyTheme.navy900.opacity(0.08) : .clear, radius: 3, y: 1)
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
                Text("ORIGINAL SCAN · PAGE \(bridge.activePageIndex + 1)")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(SkyTheme.slate600)

                Spacer()

                HStack(spacing: 6) {
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

                    Button {
                        bridge.rescanActiveBar()
                    } label: {
                        Text("Retake Row")
                            .font(.system(size: 11.5, weight: .bold, design: .rounded))
                            .foregroundStyle(SkyTheme.navy900)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(SkyTheme.line, lineWidth: 1))
                    }
                    .buttonStyle(PressableButtonStyle())
                }
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
                            .shadow(color: SkyTheme.navy900.opacity(0.06), radius: 10, y: 4)
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
                        Text("FIX IT QUEUE")
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                            .tracking(0.6)
                            .foregroundStyle(SkyTheme.wrongInk)

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
                    Text("DURATION & PITCH")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .tracking(0.6)
                        .foregroundStyle(SkyTheme.slate600)

                    let cols = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)
                    LazyVGrid(columns: cols, spacing: 6) {
                        durationChip(id: "whole", symbol: "𝅝", label: "Whole")
                        durationChip(id: "half", symbol: "𝅗𝅥", label: "Half")
                        durationChip(id: "quarter", symbol: "♩", label: "Quarter")
                        durationChip(id: "eighth", symbol: "♪", label: "Eighth")

                        durationChip(id: "16th", symbol: "𝅘𝅥𝅯", label: "16th")
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
                    Text("STUDIO TOOLS")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .tracking(0.6)
                        .foregroundStyle(SkyTheme.slate600)

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
            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
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
