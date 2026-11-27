import SwiftUI

/// Interactive Quick Guide & Keyboard Shortcuts sheet styled in the MusicScan Sky system.
struct QuickGuideSheetView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case scanAndFix = "Scan & Fix"
        case editAndPlay = "Edit & Play"
        case shortcuts = "Shortcuts"

        var id: String { rawValue }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: Tab = .scanAndFix

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Guide Section", selection: $selectedTab) {
                    ForEach(Tab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(SkyTheme.sky25)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        switch selectedTab {
                        case .scanAndFix:
                            scanAndFixContent
                        case .editAndPlay:
                            editAndPlayContent
                        case .shortcuts:
                            shortcutsContent
                        }
                    }
                    .padding(16)
                }
                .background(SkyTheme.sky25)
            }
            .navigationTitle("Quick Guide")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        #endif
    }

    // MARK: - Scan & Fix

    private var scanAndFixContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Photo Tips", subtitle: "MusicScan flattens tilt, removes colored pen marks, and evens shadows automatically.")

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                tipCard(icon: "sun.max.fill", title: "Even Light", body: "Avoid harsh glare or deep shadows across staff lines.")
                tipCard(icon: "viewfinder", title: "Fill the Frame", body: "Keep the whole printed page inside the viewfinder.")
                tipCard(icon: "doc.on.doc.fill", title: "Multi-Page", body: "Scan multiple pages in one pass—bars number straight through.")
                tipCard(icon: "crop", title: "Adjust Edges", body: "If a corner is off, tap Adjust Edges to re-read from the original photo.")
            }

            sectionHeader("Confidence Flags", subtitle: "Every bar is checked by two models so you immediately see what needs a glance.")

            VStack(spacing: 10) {
                flagRow(
                    symbol: "checkmark.circle.fill",
                    badgeText: "Sure",
                    ink: SkyTheme.sureInk,
                    fill: SkyTheme.sureFill,
                    description: "High-confidence reading. Ready to play."
                )
                flagRow(
                    symbol: "circle.fill",
                    badgeText: "Glance",
                    ink: SkyTheme.glanceInk,
                    fill: SkyTheme.glanceFill,
                    description: "Minor uncertainty or second-model note worth a quick look."
                )
                flagRow(
                    symbol: "exclamationmark.triangle.fill",
                    badgeText: "Check / Fix It",
                    ink: SkyTheme.wrongInk,
                    fill: SkyTheme.wrongFill,
                    description: "Tap Fix It to hear the bar, view your photo side-by-side, edit, or rescan the row."
                )
            }
        }
    }

    // MARK: - Edit & Play

    private var editAndPlayContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Intuitive Staff Editing", subtitle: "Edits patch the live MusicXML in place so untouched slurs, beams, and dynamics survive export.")

            featureCard(
                icon: "hand.draw.fill",
                title: "Drag Notes with Haptic Ticks",
                detail: "Tap any note and drag up or down by pitch step, or sideways to reorder. Switch to Add Notes to see a live ghost pitch preview before lifting."
            )
            featureCard(
                icon: "pencil.tip",
                title: "Apple Pencil Precision & Ink",
                detail: "Pencil grabs the exact note under the tip and previews notes on hover. Double-tap switches Select / Add, or Pen / Eraser in Ink mode. Ink strokes stay pinned to their bar inside the MusicXML file."
            )
            featureCard(
                icon: "metronome.fill",
                title: "Practice Bar & Sampled Piano",
                detail: "Play with a moving cursor and lit sounding notes even when your Silent switch is on. Loop bars, ramp tempo automatically, add a count-in, or mute/solo hands."
            )
            featureCard(
                icon: "square.and.arrow.up.fill",
                title: "Export MusicXML & MIDI",
                detail: "Export clean .musicxml (with dynamics, hairpins, fingerings, and text) or .mid directly through the iOS Share Sheet."
            )
        }
    }

    // MARK: - Shortcuts

    private var shortcutsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("iPad Hardware Keyboard", subtitle: "Hold ⌘ on any connected keyboard to see these live in the editor.")

            shortcutGroup(title: "Playback & Review", items: [
                ("⌘ ↩", "Play / Stop"),
                ("⇧ ⌘ F", "Fix It: Check Flagged Bars"),
                ("⌘ ]  /  ⌘ [", "Next / Previous Flagged Bar"),
                ("⇧ ⌘ ↩", "Mark Bar Looks Right"),
                ("⇧ ⌘ P", "Show / Hide Original Photo")
            ])

            shortcutGroup(title: "Editing & Modes", items: [
                ("⌘ 1 / ⌘ 2 / ⌘ 3", "Select / Add Notes / Ink"),
                ("⌘ Z  /  ⇧ ⌘ Z", "Undo / Redo"),
                ("A – G", "Enter Pitch (in Note Input)"),
                ("1 – 7  /  0  /  .", "Duration / Rest / Dot"),
                ("↑ ↓  /  ⌘ ↑ ↓", "Semitone / Octave")
            ])

            shortcutGroup(title: "Pages, Zoom & Export", items: [
                ("⌘ O  /  ⌘ N", "Scan a Page / New Scan"),
                ("⌘ =  /  ⌘ -", "Zoom In / Zoom Out"),
                ("⌘ S  /  ⇧ ⌘ S", "Export MusicXML / MIDI")
            ])
        }
    }

    // MARK: - Components

    private func sectionHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(SkyTheme.navy900)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(SkyTheme.slate600)
        }
    }

    private func tipCard(icon: String, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(SkyTheme.blue600)
                .frame(width: 38, height: 38)
                .background(SkyTheme.sky50, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Text(title)
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .foregroundStyle(SkyTheme.navy900)

            Text(body)
                .font(.caption)
                .foregroundStyle(SkyTheme.slate600)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(SkyTheme.line, lineWidth: 1)
        )
    }

    private func flagRow(symbol: String, badgeText: String, ink: Color, fill: Color, description: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.caption.weight(.bold))
                Text(badgeText)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(fill, in: Capsule())
            .frame(width: 118, alignment: .leading)

            Text(description)
                .font(.footnote)
                .foregroundStyle(SkyTheme.navy900)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(SkyTheme.line, lineWidth: 1)
        )
    }

    private func featureCard(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(SkyTheme.blue600)
                .frame(width: 42, height: 42)
                .background(SkyTheme.sky50, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(SkyTheme.navy900)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(SkyTheme.slate600)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(SkyTheme.line, lineWidth: 1)
        )
    }

    private func shortcutGroup(title: String, items: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(SkyTheme.slate600)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack {
                        Text(item.1)
                            .font(.subheadline)
                            .foregroundStyle(SkyTheme.navy900)
                        Spacer()
                        Text(item.0)
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                            .foregroundStyle(SkyTheme.blue700)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(SkyTheme.sky50, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)

                    if index < items.count - 1 {
                        Divider()
                            .padding(.leading, 14)
                    }
                }
            }
            .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(SkyTheme.line, lineWidth: 1)
            )
        }
    }
}

#Preview {
    QuickGuideSheetView()
}
