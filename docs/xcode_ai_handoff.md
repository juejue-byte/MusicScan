# MusicScan iOS/iPadOS — Local-First Architecture & UI Redesign Handoff (For Xcode AI)

> **Purpose:** Hand this document + [`musicscan_ios_wireframes.html`](file:///home/antigravity/.gemini/jetski/brain/v1/default/jetski_remote_agents_3p_devbox/075a5e39-3a89-4187-8926-10eb74239b21/musicscan_ios_wireframes.html) directly to your Xcode AI agent. It fixes both the **UI overload** and the **slow/expensive remote WebView** in one cohesive refactor.

---

## 1. Summary of Findings

### A. Architecture Bottleneck (Why It's Slow & Expensive Today)
- Today [`EditorWebView.swift`](file:///home/antigravity/MusicScan_upstream/ios/MusicScan/EditorWebView.swift#L270) loads the entire UI, `vexflow.js` (~1 MB), and audio samples over HTTPS from `juejue-byte--musicscan.us-east.modal.run`.
- Opening the app, browsing saved scores, editing notes, or playing back **wakes up Modal**, causing cold-start lag, compute spend, and zero offline capability.
- **Target rule:** **Modal is ONLY for stateless GPU OMR (`POST /api/scan`, `POST /api/rescan-row`) and Apple billing webhooks.** Everything else (Home, Library, Score rendering, Editing, Undo/Redo, Playback, Ink, Export, Camera flatten) runs **100% locally on-device at 0ms latency and \$0 cost**.

### B. UI Critique (Across All 8 iOS Screenshots)
1. **[P0] 6–8 stacked toolbars eat ~50% of the iPhone viewport** (and in Add mode with the piano keyboard, only ~1.5 staves remain visible).
2. **[P0] Triple-duplicated controls:** `Fix it` appears 3× simultaneously (`Fix it: check 6 bars`, `Fix it 6`, `Flags (6)` / `Red (3)`), and `Photo` appears 3× (`Photo`, `Bar photo`, `Compare`).
3. **[P1] Native iOS HIG violation:** Bottom Tab Bar (`Home | Review & Edit`) stays pinned *inside* an open score editor, stealing 64pt from the thumb zone.
4. **[P1] Developer telemetry & web slop:** `16.4s (GPU 8.0s)`, `Scan 2026-11-27T1...` ISO timestamps, `Scan quality: 55%`, `- 60% +` zoom buttons (pinch-to-zoom is native), clipped buttons (`Retake photo`), and `×` delete badges covering Library thumbnails.
5. **[P1] Pre-launch ID mismatch:** `project.pbxproj` still has `com.example.musicscan` while `Info.plist`, `AppConfig.swift`, and `MusicScanProducts.storekit` use `com.allenjue.musicscan` + `com.allenjue.musicscan.pro.yearly/.monthly`. Unify before submission.

---

## 2. Revised Wireframes (iPhone Compact vs. iPad Regular)

> Interactive clickable version: **[`musicscan_ios_wireframes.html`](file:///home/antigravity/.gemini/jetski/brain/v1/default/jetski_remote_agents_3p_devbox/075a5e39-3a89-4187-8926-10eb74239b21/musicscan_ios_wireframes.html)**

### 2.1 iPhone (`horizontalSizeClass == .compact` — 390pt)
- **Hide Tab Bar** when pushing into a score (`.toolbar(.hidden, for: .tabBar)`).
- **1 single 44pt native top bar** + **~78% score canvas** + **1 adaptive bottom glass dock**.

```text
┌─────────────────────────────────────┐
│ ‹ Scores   Waltz in C Minor ▾  ↶  ↑ │  ← Single 44pt nav bar (Title ▾ opens Rename, Pages, Adjust Edges, Retake, Export)
├─────────────────────────────────────┤
│  ┌───────────────────────────────┐  │
│  │ [ONLY in Fix mode: Cropped    │  │  ← Appears inline ONLY when Fix (6) is active
│  │  Original Photo of Active Bar]│  │
│  └───────────────────────────────┘  │
│                                     │
│     Full-Bleed Local VexFlow        │
│     Sheet Music Canvas (~78%)       │  ← Native pinch-to-zoom; tap any bar to select
│     Subtle amber/red bar tints      │
│                                     │
├─────────────────────────────────────┤
│  DEFAULT (Play):                    │
│  [ ▶ Play ] [ Fix 6 ] [ Edit ] [⚙] │  ← Single 56pt floating glass dock (≥44pt targets)
│                                     │
│  WHEN "Fix 6" TAPPED:               │
│  ‹ Bar 2 (2/6) ›              Done  │
│  [ ✓ Looks Right ]  [ Edit Notes ]  │
│                                     │
│  WHEN "Edit" TAPPED:                │
│  [Drag | +Note | Rest | Ink]  Done  │
│  [ 𝅗𝅥 ] [ ♩ ] [ ♪ ] [ ♯ ] [ ♭ ] [⌫]  │  ← Optional mini-keyboard toggle inside "+Note"
└─────────────────────────────────────┘
```

### 2.2 iPad Studio (`horizontalSizeClass == .regular` — 1024–1366pt)
- **Single 52pt top bar** + **3-region direct-access workspace** (no popups needed).

```text
┌───────────────────────────────────────────────────────────────────────────┐
│ ‹ Scores  Waltz in C Minor ▾ [Pg 1/2] │ [Drag|+Add|Ink] │ ↶ ↷ [▶ Play] ♩=96 ↑ │
├────────────────────┬────────────────────────────────┬─────────────────────┤
│ ORIGINAL SCAN (30%)│   EDITABLE SCORE CANVAS (48%)  │ INSPECTOR RAIL (22%)│
│ [Edges] [Retake]   │                                │                     │
│                    │   Full-page VexFlow engraving  │ FIX IT QUEUE (6)    │
│  Synced photo      │   + PencilKit PKCanvasView     │ ┌─────────────────┐ │
│  locked to         │     overlay for Apple Pencil   │ │ Bar 2 · Rhythm  │ │
│  active Bar 2      │                                │ │ [✓ OK] [Next ›] │ │
│                    │   Click to add / Drag pitch    │ └─────────────────┘ │
│  (Toggleable)      │                                │                     │
│                    │                                │ DURATION & PITCH    │
│                    │                                │ [𝅝][𝅗𝅥][♩][♪][♬][·] │
│                    │                                │ [♯][♭][♮][Rest][⌫]  │
│                    │                                │ 🎹 Piano · ⟲ Loop   │
└────────────────────┴────────────────────────────────┴─────────────────────┘
```

### 2.3 Home & Library Polish (Keep Existing Sky Design)
- **Home (`HomeView.swift`):** Keep current clean layout; ensure `Scan Sheet Music` subtitle does not truncate (`"Pick or photograph sheet music"`).
- **Library (`ScoreLibraryView.swift`):**
  - Replace raw ISO names (`Scan 2026-11-27T1...`) with clean titles (`Nov 27 · 33 bars` or detected piece title).
  - Remove the floating `×` delete circle over thumbnails — use iOS `.contextMenu` (`Rename`, `Export MusicXML`, `Export MIDI`, `Delete`).

---

## 3. Step-by-Step Implementation Blueprint (Local-First)

### Step 1: Bundle `web/` Inside Xcode & Serve Locally via `WKURLSchemeHandler`
Add the `web/` folder (`index.html`, `style.css`, `review.css`, `js/`, `vendor/vexflow.js`, `vendor/sounds/`) as a **Folder Reference** (blue folder) in Xcode's `Copy Bundle Resources`.

Create `ios/MusicScan/LocalWebSchemeHandler.swift`:
```swift
import Foundation
import WebKit

final class LocalWebSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "musicscan-app"
    private let rootURL: URL

    init(bundleSubdir: String = "web") {
        self.rootURL = Bundle.main.resourceURL!.appendingPathComponent(bundleSubdir, isDirectory: true)
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        var relPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if relPath.isEmpty { relPath = "index.html" }
        let fileURL = rootURL.appendingPathComponent(relPath).standardizedFileURL

        guard fileURL.path.hasPrefix(rootURL.standardizedFileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let response = URLResponse(
            url: url,
            mimeType: Self.mimeType(for: fileURL.pathExtension),
            expectedContentLength: data.count,
            textEncodingName: fileURL.pathExtension == "html" ? "utf-8" : nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html"
        case "js", "mjs": return "application/javascript"
        case "css": return "text/css"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "ogg": return "audio/ogg"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }
}
```
Register it on `WKWebViewConfiguration`:
```swift
config.setURLSchemeHandler(LocalWebSchemeHandler(), forURLScheme: LocalWebSchemeHandler.scheme)
// Load instantaneously from local bundle (zero network!):
webView.load(URLRequest(url: URL(string: "musicscan-app://local/index.html?embed=native")!))
```

---

### Step 2: Create `LocalScoreStore.swift` (On-Device Score Persistence)
Store every score in `Application Support/MusicScan/Scores/<scoreID>/`:
- `meta.json` — `id`, `title`, `createdAt`, `updatedAt`, `pageCount`, `barCount`, `flaggedCount`, `tempoBPM`
- `score.musicxml` — canonical MusicXML (mutated locally on every edit/fix)
- `flags.json` — per-bar confidence & verified status
- `page_1.jpg`, `page_2.jpg`, ... — flattened original scans for instant offline Fix-It comparison
- `thumb.jpg` — fast 400px thumbnail for `ScoreLibraryView`
- `ink.pkdrawing` — native `PencilKit` `PKDrawing.dataRepresentation()`

All Library reads, renames, deletes, exports, and editor opens read directly from `LocalScoreStore` with **zero network calls**.

---

### Step 3: Strip WebView Chrome (`?embed=native`) + Swift ↔ JS Bridge
In `web/style.css`, hide all HTML toolbars when embedded inside the native SwiftUI shell so the WebView renders **only the clean VexFlow score canvas**:
```css
body.native-embed header.top,
body.native-embed .title-bar,
body.native-embed .quality-banner,
body.native-embed .mode-strip,
body.native-embed .fix-subbar,
body.native-embed .bottom-status {
  display: none !important;
}
body.native-embed main.score-viewport {
  padding: 8px 10px 96px !important; /* breathing room above floating SwiftUI dock */
}
```

**Swift → JS commands** (`webView.evaluateJavaScript(...)`):
- `window.MusicScanNative.loadScore({ xml, flags, tempo })`
- `window.MusicScanNative.setMode('play' | 'fix' | 'edit' | 'ink')`
- `window.MusicScanNative.setEditTool({ tool: 'drag' | 'note' | 'rest', dur: 'q', accidental: 0 })`
- `window.MusicScanNative.transport('play' | 'stop' | 'toggleLoop')`
- `window.MusicScanNative.fixNav('prev' | 'next' | 'markOK')`
- `window.MusicScanNative.undo()` / `redo()`

**JS → Swift callbacks** (`window.webkit.messageHandlers.musicscan.postMessage(...)`):
- `{ type: 'xmlChanged', xml: '<score-partwise>...' }` → `LocalScoreStore.saveXML(...)`
- `{ type: 'activeBarChanged', barIndex: 2, pageIndex: 0, cropRect: {x,y,w,h} }` → updates iPhone inline photo crop & iPad left-pane highlight
- `{ type: 'flagsUpdated', remaining: 5, total: 6 }` → updates badge on `Fix (5)` button
- `{ type: 'playbackState', playing: true, barIndex: 2 }` → syncs Play/Stop icon

---

### Step 4: On-Device Preprocessing + Modal GPU OCR Only
1. Capture photo in `ManualDocumentCameraView.swift` (`Vision` quad lock + `CoreImage` `CIPerspectiveCorrection`).
2. Optionally run a fast on-device `CIFilter` HSV saturation mask to strip red/blue pen ink, resize long edge to `2000px`, compress to JPEG (`0.82`, ~200 KB).
3. Send **only that JPEG** to `POST https://allenjue--musicscan-web.modal.run/api/scan` (with user's Supabase JWT).
4. Modal runs `copista-28m` + `sanitize_musicxml()` → returns `{ musicxml, flags, pages }`.
5. iOS saves result into `LocalScoreStore`, opens `ScoreEditorContainerView` immediately, and **never hits Modal again** for that score unless the user taps **Retake Row / Retake Photo**.

---

### Step 5: Interaction & Motion Polish (Emil Design Eng Tokens)
Apply these exact SwiftUI specs across all new chrome:
- **Press feedback:** `.scaleEffect(configuration.isPressed ? 0.96 : 1.0)` with `.animation(.easeOut(duration: 0.15), value: configuration.isPressed)` on every dock button.
- **Dock & Fix-It transitions:** `.animation(.spring(response: 0.28, dampingFraction: 0.88), value: editorMode)` (interruptible, snappy, zero bounce).
- **No `scale(0)` entrances:** Popovers/menus enter from `scale(0.95)` + `opacity(0)` anchored to their trigger (`UnitPoint.top`).
- **Haptics:** `.sensoryFeedback(.impact(flexibility: .soft), trigger: selectedBar)` on bar tap; `.sensoryFeedback(.success, trigger: verifiedCount)` when tapping `✓ Looks Right`.
- **Reduce Motion:** Respect `@Environment(\.accessibilityReduceMotion)` — crossfade instead of sliding sheets.
- **Touch targets:** Minimum `44 × 44 pt` on every interactive control; use **SF Symbols** exclusively (`chevron.left`, `arrow.uturn.backward`, `square.and.arrow.up`, `play.fill`, `checkmark.circle.fill`, `pencil.tip`, `slider.horizontal.3`).
