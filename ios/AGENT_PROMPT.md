# Prompt for a Claude agent developing the MusicScan iOS app in Xcode

Paste everything below the line into Claude Code, started on your Mac in the repo folder (`cd MusicScan && claude`).

---

You are continuing development of **MusicScan**, an app that turns photos of printed sheet music into an editable,
playable score (MusicXML / MIDI). Repo: https://github.com/juejue-byte/MusicScan (you are in its root folder on my
Mac). The web MVP works; your job is the iOS app in `ios/`, which has been written but **never compiled**. The person
you work for is Allen; he wants a polished MVP, with upload, edit, play and preview that feel nice, and note dragging
that feels intuitive on a phone.

## Read first (in this order)
1. `SPEC.md`: product scope and stack.
2. `ios/README.md`: what the app does, why it is a native SwiftUI shell (not Capacitor), build and signing steps.
3. `ios/MusicScan/*.swift`: the app (~440 lines). `EditorWebView.swift` holds the WKWebView and the JS bridge.
4. `web/js/native.js`: the web side of the bridge. Messages: `scan`, `share`, `haptic`, `settings`;
   web -> native via `window.webkit.messageHandlers.musicscan.postMessage({id, cmd, ...})`,
   native -> web via `window.__msNativeReply(id, result)`.
5. `web/js/app.js` (editor UI, pointer/touch handling, upload flow), `score.js` (MusicXML DOM model; edits patch
   `<note>` elements in place), `render.js` (VexFlow layout + hit-test map), `audio.js` (playback).
6. `server/app.py`: FastAPI backend. Endpoints: `POST /api/jobs` (multipart `file`, `detector` 28m|2m) -> `{id}`;
   `GET /api/jobs/{id}` (poll; `status` = queued / Cleaning up the photo / Reading the music / done / error, and
   `result` with `xml`, `measures`, `systems`, `quality`); `GET /api/jobs/{id}/page.png|original.jpg`;
   `POST /api/jobs/{id}/rescan` (`measures` "3,4", `attempt`, optional close-up `file`); `GET /api/samples`.
   The web app is served from `/`.

## Architecture (keep it)
- OMR runs on the server (copisteria, Python). The app captures with VisionKit's `VNDocumentCameraViewController`
  and uploads through the same web code path (`startUpload` in app.js).
- The app loads the editor from the server URL in a WKWebView (address in Settings, default
  `MUSICSCAN_SERVER_URL` build setting; the simulator uses `http://localhost:8000`).
- Keep one editor for web and iOS. Native-only behaviour goes through `native.js` and must degrade to the normal web
  behaviour in a browser (`isNative` is false there).

## Set up and run
```bash
scripts/setup.sh                 # Python 3.12+ venv, copisteria (pinned) + weights (~140 MB); needs Homebrew python@3.12 or uv
HOST=0.0.0.0 scripts/run.sh      # server on port 8000, reachable from the phone on the same Wi-Fi
open ios/MusicScan.xcodeproj     # or build from the command line:
xcodebuild -project ios/MusicScan.xcodeproj -scheme MusicScan -destination 'platform=iOS Simulator,name=iPhone 15' build
```
If `xcodebuild` says the scheme is missing, open the project in Xcode once (it creates the scheme) or use
`-target MusicScan -sdk iphonesimulator`. Signing for a device: target > Signing & Capabilities > Team (Allen's
Apple ID); change the bundle id `com.example.musicscan` if it is taken. Ask Allen before changing his signing team.

Web checks (Node 18+ and Playwright: `npm i -D playwright` in a scratch folder if missing):
```bash
node tests/touch.js http://localhost:8000/ bench/data/bach_bwv66.musicxml /tmp/touch   # emulated iPhone + fake bridge
node tests/e2e.js http://localhost:8000/ /tmp/e2e                                      # full web flow
python -m pytest tests -q
```

## First tasks, in order
1. **Make it compile and run** in the simulator with zero warnings you introduced. The Swift was written without a
   compiler; expect small fixes (concurrency annotations on WebKit/VisionKit delegate methods, `callAsyncJavaScript`
   signature, etc.). Fix, don't redesign.
2. **Verify each flow on the simulator, then on Allen's iPhone if he connects it**: Scan a page (photo picker on the
   simulator, document camera on device) -> progress -> editor; drag a note up/down and sideways; Add notes by
   touch; Play (also with the silent switch on); Export MusicXML and MIDI via the share sheet; "Can't reach the
   server" screen and the Server settings sheet; rotation; iPad layout.
3. **Polish what feels off on a real phone**: tap target sizes in the toolbar, safe areas, keyboard, the progress
   screen, haptics strength, scroll vs. drag conflicts on the score. Make web changes in `web/` so the browser
   benefits too, and rerun `tests/touch.js`.
4. Then, if time allows: multi-page scans (today only page 1 of a document-camera scan is read), bundling `web/`
   into the app for faster start (serve it via a `WKURLSchemeHandler` and point only `api/` at the server), and an
   https server option so `NSAllowsArbitraryLoads` can be removed.

## Rules
- Scope: printed music only (no handwriting); piano or single-instrument parts, at least two staves (treble+bass,
  alto clef, double bass).
- Every dependency must be usable commercially. Do not add AGPL/GPL code (no homr, Audiveris, pillow-heif) and do
  not statically link LGPL code (Verovio) into the app. Keep the visible credit "OMR by copisteria © KobiMusic
  (Apache-2.0)" required by its NOTICE; see `THIRD_PARTY_NOTICES.md`. Prefer Apple frameworks over packages.
- Git: Allen approved pushing straight to `main`. Before each push: `git pull --rebase origin main` (other agents
  push to main too). Small commits with clear messages. Never force-push. Don't commit `xcuserdata`, DerivedData or
  signing files.
- Don't break the web app: anything in `web/` must keep working in desktop and mobile browsers.
- When something can't be verified (for example no device connected), say so plainly in your summary.
