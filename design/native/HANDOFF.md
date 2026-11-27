# MusicScan native iOS: SwiftUI handoff

One section per screen. Each one can be pasted to the Xcode agent on its own. Pictures are in `wireframes/<name>.png`
(2x). Colours, radii and type come from `design/sky/tokens.json`. Live canvas with comments:
https://claude.ai/artifact/Pow6gYwDqCR1P58MCroT4b

## Shared rules (paste once, before any screen)

- Replace the web view with native SwiftUI. iPad landscape first (1194 x 834 pt is the reference), iPhone second.
- Navigation: `NavigationSplitView` on iPad (Library sidebar + detail), `NavigationStack` on iPhone.
  Scan is a `.fullScreenCover`. Sign in, Export and the iPhone paywall are `.sheet`s. Fix it and Practice are
  pushed destinations of Edit with a "Done" button.
- Colours (make an asset catalog): sky25 #F5FAFF app background, sky50 #EAF4FE bars/wells, sky100 #D8EAFC selection
  (text blue700 #0F56A3), blue600 #1769C2 the one primary/tint, navy900 #0E2238 text and the dark practice bar,
  slate600 #4E647C secondary text, line #D6E4F2, marigold #F6B93B only for the Pro badge.
  Flags: sure #1D7A4E on #E2F5EA (checkmark), glance #8A5300 on #FFF1D6 with #E39B1B (filled circle),
  wrong #C2362B on #FDE8E6 (triangle). Always pair flag colour with its shape.
- Type: titles `.font(.system(size:, weight: .black, design: .rounded))`; everything else the default system font,
  Dynamic Type on.
- Shape: radius 10 controls, 14 buttons, 20 cards, 28 sheets. Primary buttons are capsules 52 to 56 pt tall.
  Minimum hit area 44 pt.
- Floating toolbars over the music: capsules with `.glassEffect()` on iOS 26 (fallback `.ultraThinMaterial` +
  1 pt white stroke + soft blue shadow). The music page is always plain white.
- Icons: SF Symbols in the app (the canvas draws stand-ins). Suggested names are given per screen.
- Rows as printed: the score keeps each printed system on one row and zooms to fit the widest row; only upright
  iPhone wraps rows.

## Main · App map

Flow: Welcome -> Sign in sheet -> Library (home). Library -> Scan (full-screen) -> Photo check only when the photo
will read badly -> Edit. Edit -> Fix it / Practice (push) and Export (sheet). Paywall appears on the second page on.
Settings from the account row at the bottom of the Library sidebar (iPad) or the avatar (iPhone).

## iPad 1 · Welcome (first launch)

- `TabView(.page)` with 3 pages; this is page 1. Left 560 pt panel sky100 with art: two page thumbnails, blue
  viewfinder corners (logo motif), a "12 bars read" chip and a dark "♩ = 96" play chip.
- Right: logo + "MusicScan", title "Scan it. Fix it. Play it." (60 pt rounded black, "Fix it." in blue600),
  body copy, 3 step rows (icon tile 52 pt: `viewfinder`, `pencil`, `play.fill` on navy).
- Footer: capsule "Get started" (blue600) -> Sign in sheet; "Your first full page is free."; page dots.
- Show only once (`@AppStorage("didOnboard")`).

## iPad 2 · Sign in

- `.sheet` with `.presentationDetents([.large])`, form-sheet size on iPad (~520 pt wide), close button top right.
- App icon tile, title "Keep your music safe", 2 reason rows (`icloud`, `lock.shield`).
- `SignInWithAppleButton(.signIn)` black, full width, 54 pt. Then "Continue with email" (outlined, `envelope`).
  "Not now" text button keeps the anonymous Supabase session. Fine print links Terms and Privacy.

## iPad 3 · Library (Open)

- `NavigationSplitView`. Sidebar (sky50, 300 pt): logo row; `List` rows All music (selected = sky100 fill,
  blue700 text, count), Recent (`clock`), Needs a look (amber dot + count badge), Practising (`music.note`);
  section "Folders" with folders + "New folder". Bottom: account row (avatar initial, name, "1 free page left" or
  "Pro") -> Settings.
- Detail: toolbar `line.3.horizontal.decrease` (sort/view), `square.and.arrow.down` (import from Photos/Files),
  "Select". Large title "All music", `.searchable` ("Search titles and composers").
- `LazyVGrid` 4 columns: card = page thumbnail (radius 14, top-aligned crop, 206 pt tall), title (semibold 15),
  "Composer · N pages", status pill (green "Ready" / amber "N bars to check").
- Floating capsule "Scan music" (`viewfinder`, 64 pt, blue600, big shadow) bottom-right -> Scan.
- Context menu on a card: Rename, Move to folder, Share, Delete.

## iPad 4 · Scan (just the camera)

- `.fullScreenCover`, edge to edge, status bar hidden. Live camera (AVFoundation or VisionKit's
  `VNDocumentCameraViewController` if we keep it; custom view preferred so it looks like this).
- Detected page drawn as a quad: fill blue400 at 16%, 3 pt blue400 stroke, white 6 pt corner brackets.
- Top-left close (`xmark`) in a dark glass circle. Top-centre status pill: green check + "Page found · hold still"
  (other states: "Looking for the page…", "Move closer", "Too dark").
- Right rail (iPad landscape): flash (`bolt.badge.automatic`), shutter (88 pt white ring), photo import
  (`photo.on.rectangle`). Bottom-left "Auto-capture" pill. Nothing else on screen.
- Auto-capture fires when the quad is stable for ~0.8 s. Haptic `.success` on capture.

## iPad 5 · Photo check / retake

- Shown only when the quality check says the photo will read badly (shadow, blur, too dark, page cut off).
  Good photos go straight to reading/Edit.
- Captured photo on the left over a blurred, darkened copy of itself. Back chevron -> camera.
- Right card (420 pt, radius 28): red triangle tile, title "This photo may read badly", one-line reason, checklist
  rows (red triangle for the problem with a fix tip, green checks for what passed).
- Buttons: "Retake" (primary, `arrow.triangle.2.circlepath`), "Use this photo anyway" (sky50 fill), text
  button "Adjust edges" (opens the corner editor).

## iPad 6 · Edit

- Background sky25. Floating glass row on top: left capsule "‹ Library"; centre title button (rounded black
  "Sonata facile" + chevron, subtitle "Mozart · Page 1 · Piano") opens rename / page picker; right capsule undo
  (`arrow.uturn.backward`), redo, divider, photo toggle (`photo`, shows the photo beside the score), share
  (`square.and.arrow.up`) -> Export; separate 52 pt blue play circle -> Practice.
- White page card (radius 20) with the score, rows as printed. Top-left meta (tempo, key, time); top-right amber
  chip "▲ 2 bars to check · Fix it ›" -> Fix it.
- Flags: bar tinted with flag fill, glance = dashed amber outline, wrong = solid; a small white badge with the flag
  shape at the bar's top-right corner. Selection = sky100 fill + 2 pt blue600 border.
- Under the card: dashed "+ Scan page 2" button and a hint line for the current selection.
- Bottom floating glass palette (68 pt): segmented Notes / Marks / Ink, then whole, half, quarter (selected),
  eighth, sixteenth, dot | rest | flat, natural, sharp | tie, more (`ellipsis`). Picking a length or rest converts
  the selection directly (no rest toggle). Hardware keys per `SHORTCUTS` in web/js/app.js.
- Apple Pencil writes into the staff; Pencil double-tap toggles pen/eraser in Ink.

## iPad 7 · Fix it

- Pushed from Edit. Top bar: "Done", centred "Fix it" + "1 of 2 bars to check", progress segments.
- Left column: card "Your photo · bars 5 and 6" (crop of the cleaned photo, the flagged bar ringed in red, the
  rest dimmed), card "What we read" (engraved bars, flagged bar tinted). Keep both crops aligned bar for bar.
- Right column: flag pill + bar number, title "Does bar 6 match your page?", one-sentence reason from the reader.
  Actions: "Looks right" (green, Return), "Try the second reading" (2), "Edit this bar" (E, jumps to Edit with
  the bar selected), "Skip for now".
- Bottom: strip of all bars coloured by flag; tap to jump. After the last bar, auto-return to Edit with a toast.

## iPad 8 · Practice

- Pushed from Edit (or play button). Top: "Done", title, sound picker capsule ("Grand piano", `pianokeys`).
- Score card: loop region = sky50 band with sky400 border and two blue drag handles; current bar sky100; playhead
  3 pt blue600 line with a soft halo; auto-scroll by row.
- Bottom dark bar (navy900, radius 28, the only dark surface): progress scrubber with "Bar 2 of 8" and time;
  restart, 64 pt white pause/play, tempo − "♩ 96 · 80% speed" +, Loop toggle (blue when on), Hands segmented
  Both / Right / Left, Click (metronome) toggle, Count-in toggle.

## iPad 9 · Export / share

- `.sheet` (form sheet ~580 pt) over Edit. "Cancel" + "Share" title.
- Score summary row (thumbnail, title, "Mozart · 1 page · 8 bars · checked").
- Format radio cards: MusicXML (default; "Opens in MuseScore, Dorico, Finale and Sibelius"), PDF, MIDI.
- Primary "Open in MuseScore": writes `<title>.musicxml` to a temp URL and presents
  `UIActivityViewController` / `ShareLink` so the user picks MuseScore (or "Open in…"). Secondary "Save to Files"
  (`UIDocumentPickerViewController(forExporting:)`) and "More…" (system share). Tip line about AirDrop to a Mac.
- Gate: when locked, these buttons open the paywall instead.

## iPad 10 · Paywall (half-page preview)

- Shown when a non-Pro user opens a page after their free one, or taps Edit/Play/Export on a locked page.
- Left: the page card showing the top half of the reading sharp; bottom half blurred (`.blur(radius: 9)` +
  white gradient) with a navy lock circle, "The rest of this page is ready", "All 12 bars were read…".
- Right card (Superwall-hosted UI is fine if it matches): marigold "PRO" badge, "Unlock every page you scan",
  4 feature rows, plans Yearly $99.99 ("$8.33 a month, billed yearly", default, "Best value · save 48%") and
  Monthly $15.99. No trial, no weekly. "Continue" capsule. Fine print with auto-renew terms and "Up to 30 pages a
  month" (fine print only). Restore purchases, Terms, Privacy links. StoreKit 2 underneath with server check.

## iPad 11 · Settings and account

- `NavigationSplitView` again: sidebar "Settings" with rows Account and plan, Scanning, Editing, Playback, Help and
  feedback, About/terms/privacy (coloured 30 pt icon tiles, iOS Settings style).
- Account and plan: profile card (initial, name, "Signed in with Apple · syncing on", PRO badge). Plan group:
  "MusicScan Pro · Yearly · renews <date>", "Manage subscription" (`showManageSubscriptions`), "Restore purchases".
  Scanning toggles: auto-capture, photo warning. Account: "Sign out", "Delete account and all scans" (red; App Review
  requires in-app deletion).

## iPhone · Library

- `NavigationStack`, large title "Your music", avatar button top-right -> Settings, `.searchable`, filter chips
  (All / Needs a look · 2 / folders), 2-column grid of cards, floating centred "Scan music" capsule.

## iPhone · Scan

- Same as iPad Scan, portrait: close top-left, flash top-right, status pill under the page, bottom row = Photos
  import, 82 pt shutter, Auto indicator.

## iPhone · Edit

- Compact top bar: back chevron, centred title + "Page 1 · Piano", share, small blue play circle.
- Score card wraps rows when upright (hint "Turn sideways for rows as printed"); landscape uses rows as printed.
- Bottom palette sheet (radius 24 top corners, glass): Notes/Marks/Ink segmented + undo/redo, then a 6 x 2 grid of
  tools (lengths and dot; rest, flat, natural, sharp, tie, more).

## iPhone · Practice

- "Done" + title; score card with loop label, current bar and playhead; dark bottom bar: progress, tempo − / +,
  64 pt pause, loop and click toggles, Hands segmented.

## iPhone · Paywall

- Preview card on top (top half sharp, rest blurred). Bottom sheet (`.presentationDetents([.fraction(0.63)])`,
  grabber): PRO + "You used your free page", title, plans (Yearly default, Monthly), Continue, fine print,
  Restore / Terms / Privacy / Not now.
