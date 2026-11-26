# MusicScan v1 spec (updated 2026-11-26)

Full version with the dependency audit and reasoning: https://claude.ai/artifact/SrprMA3VxhnWeZSvBctwdc

## Goal
An app, iPad first, then iPhone and the web, that turns photos of **printed** sheet music (piano grand staff or one
instrument; treble, bass, alto, tenor clefs; read row by row) into clean MusicXML, shows which bars are uncertain,
lets the user fix them on the staff or rescan them, mark them up, practise with playback and export MusicXML / MIDI.
Choir/SATB keeps working but gets no new effort; lyrics and handwritten music are out of scope.

## Plans and pricing
One paid plan, **MusicScan Pro**, as an Apple auto-renewing subscription (no weekly plan):

| Plan | Price | Includes |
| --- | --- | --- |
| Free | $0 | 1 full page with every feature for new users; after that each scan previews the first half of the page and blurs the rest, and edit / play / export ask to unlock |
| Pro monthly | $15.99 / month | up to 30 pages a month, whole pages, editing, rescans, practice playback, export, multi-page scores |
| Pro yearly | $99.99 / year ($8.33 / month) | the same, with a 7-day free trial for intro-offer eligible users |

Built: the paywall UI (`web/js/paywall.js`, `PLAN` holds prices and copy; off unless `?paywall`). To do before App
Review: StoreKit 2 purchase / restore / manage, server-side entitlement check and page counting, the server sending
only the first half of a preview page, public privacy policy and terms (see `docs/AGENT_PROMPTS.md`, Stream 5).

## Stack
| Layer | Choice | Notes |
| --- | --- | --- |
| OMR | copisteria 1.3.4 + copista-28m (copista-2m for fast mode and rescans) | Apache-2.0 code and weights; credit KobiMusic (NOTICE) |
| Server | FastAPI, background jobs with polling | `server/app.py` |
| Images | Pillow, `pi-heif` (decode only), `pypdfium2`, OpenCV headless | not `pillow-heif` (GPL x265 in wheels) |
| Cleanup | page lock (largest quadrilateral → perspective warp), colored-pen removal (Lab, relative to paper), shadow flattening (background division), all automatic; corners can be placed by hand (`POST /api/jobs/{id}/reread`) | `musicscan/preprocess.py`, `web/js/corners.js` |
| Confidence | per symbol: min probability over class / staff position / dots / accidental heads; per bar: count below 0.85 plus a second reading (copista-2m) that fills missed notes and marks bars where the two disagree; per photo: image checks + share of uncertain symbols | `musicscan/omr.py`, `quality.py`, `sanitize.py` |
| Editor | VexFlow 4 drawing a live MusicXML DOM; edits patch `<note>` elements | `web/js/` |
| Playback | Web Audio look-ahead scheduler, bundled FluidR3 GM samples (12 instruments), synth fallback; practice panel: tempo, speed-up per loop, count-in, click, mute/solo/volume per hand or voice | `web/js/audio.js`, `web/js/practice.js` |
| Export | MusicXML from the DOM, MIDI written in the browser | no server round trip |
| Not used | homr, Audiveris (AGPL), OSMD (not needed) | |

## Core flows
1. **Upload**: drag/drop, file picker, phone camera with a live photo check (light, sharpness, steadiness, page fill),
   paste; VisionKit document camera on iOS; samples and Your music (every score kept on the device) on the start screen.
2. **Transcribe**: job → cleanup → OMR → confidence → editor. Typical 9–12 s on a 4-core CPU for a scan (28m plus the second reading; the big detector reads the page once, see `omr.page_inputs`), 15–20 s for a hard photo, ~4 s fast mode.
3. **Quality warning**: banner good / check / retake with reasons (too small, blurry, dark, many uncertain symbols);
   **Adjust edges** lets the user drag the four page corners on the original photo and read the page again.
   **Fix it** steps through the flagged bars (photo beside the reading, play the bar, Looks right / Edit / Rescan /
   Second reading).
4. **Edit**: select + drag pitch, keyboard like MuseScore/Dorico (N note input with a caret, A–G letters, 1–7 lengths with 5 = quarter, 0 rest, R repeat, ↑↓ semitone, Alt+↑↓ step, ⌘↑↓ octave, `.`, ♭♮♯, Del; ? lists every shortcut), Add-notes mode with ghost preview, chords,
   undo/redo, bar-length check; voices, ties, tuplets, split / join / insert / delete bars, key / time / clef fixes,
   transpose, copy / paste; on-screen piano on iPad. Tap the title to rename the score (`<work-title>`, export names).
   **Markup**: dynamics, hairpins, fingering, text, rehearsal marks, articulations and slurs as real MusicXML;
   freehand ink (Apple Pencil) stored inside the file.
5. **Rescan**: selected bars → rows re-read from the cleaned page (second model, enlarged, high-contrast; or a close-up
   photo) → side-by-side comparison → splice (key/time/clef inherited; bar-count changes allowed with a warning).
6. **Pages**: a score is a list of pages, each its own reading (job). A new page is read with the context in force at
   the score's end (part layout and clefs always; time unless the page prints one; key unless none was read; a
   differing key is kept and flagged) and appended (`web/js/pages.js`); PDFs read page by page in the background.
   Reorder / remove / retake restate key, time and clefs where bars move. Rescans and the photo panel use the bar's page.
7. **Practise / export**: cursor follows the bar; starts at the selected bar; loop, tempo, speed-up per loop, count-in,
   click, mute / solo per hand; practice bar while playing; `.musicxml`, `.mid`.

## iOS plan
Server inference for v1; VisionKit document camera for capture; the same editor in a WKWebView inside a native
SwiftUI shell (`ios/`, chosen over Capacitor: four native features, no Node/CocoaPods; bridge in `web/js/native.js`). On-device OMR only after porting copista-2m to Core ML and the Python pipeline to Swift. Verovio is not used in
the app (LGPL static-linking question avoided).

## Hosting
Local (`scripts/run.sh`) or Modal with a GPU, HTTPS and an access key (`deploy/README.md`).

## Deferred
Accounts and cloud sync (scores live on the device), handwritten music, lyrics, batch capture (page by page is fine).

## Parallel work
`docs/AGENT_PROMPTS.md` splits the remaining work into six streams with file ownership and done criteria: iOS app,
photo to rows, reading quality, server / hosting / speed, plans and payments, web editor and practice.
