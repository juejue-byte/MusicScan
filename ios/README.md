# MusicScan for iPad and iPhone (prototype)

**iPad first.** Scores need width, so the iPad (landscape, portrait, Split View) is the main target; iPhone works
too. One universal app, iOS/iPadOS 16+.

A small native shell around the MusicScan web editor. Reading the music stays on the MusicScan server (your Mac for
now), exactly as in the [spec](../SPEC.md); the app adds what a phone does better than a browser tab:

| In the app | How |
| --- | --- |
| **Scan a page** | Apple's document camera (VisionKit): finds the page edges, flattens it, then uploads it like any photo. On the simulator it opens the photo picker instead. |
| **Edit** | The same editor as the web app, in a `WKWebView`. Drag notes with a finger (with a tick of haptic feedback per step), Add-notes mode shows the note under your finger and writes it when you lift. |
| **Play** | Sampled piano through Web Audio; plays with the ring/silent switch on. |
| **Export** | MusicXML / MIDI open the share sheet: Save to Files, AirDrop, Mail, another app. |
| **Apple Pencil** | Precise: it grabs exactly the note under the tip (fingers get a wider hit area). Hovering (M2 iPad Pro and newer) previews the note in Add mode; the note is written when the tip lifts. Double-tap (or squeeze) switches Select / Add notes. |
| **Keyboard** | With a hardware keyboard, hold ⌘ to see the shortcuts: ⌘Z / ⇧⌘Z undo/redo, ⌘↩ play/stop, ⌘1 Select, ⌘2 Add notes, ⇧⌘P photo, ⌘= / ⌘- zoom, ⌘S / ⇧⌘S export MusicXML / MIDI, ⌘O scan, ⌘N new scan. Plain keys work as on the web: ↑↓ pitch, 1–6 duration, `.` dot, R rest, Delete, Space play. |
| **Layout** | Landscape shows the photo beside the score; portrait and wide Split View keep the full toolbar; narrow Split View and Slide Over use the phone layout. A trackpad or mouse works like on a desktop. |
| **Server** | "Server: …" on the start screen (or the error screen) sets the address. |

## Why a native shell and not Capacitor

The editor is plain ES modules with no build step, and only four things need native code (document camera, share
sheet, haptics, server address). A ~450-line SwiftUI app does that with nothing to install: no Node, no CocoaPods, no
plugins. VisionKit is used directly instead of through a third-party Capacitor plugin. If the app later grows many
native features (push, in-app purchase, offline storage), moving the same `web/` folder into Capacitor stays possible:
the bridge is one file, [`web/js/native.js`](../web/js/native.js).

The app loads the editor from the server rather than bundling it, so the app and server are always the same version
while things change quickly. For the App Store we would bundle `web/` into the app and point only `api/` at a hosted
server (and use https).

## Build and run (about 10 minutes the first time)

You need a Mac with **Xcode 15 or newer** (free from the Mac App Store) and the MusicScan server set up
(`scripts/setup.sh` in the repo root, see the main README).

### 1. Start the server so the phone can reach it

```bash
cd MusicScan                 # the repo
HOST=0.0.0.0 scripts/run.sh  # listens on your Wi-Fi, port 8000
```

If macOS asks whether Python may accept incoming connections, click **Allow**. Find the Mac's address in
**System Settings > Wi-Fi > Details… > IP address** (something like `192.168.1.20`).

### 2. Open the project

```bash
open ios/MusicScan.xcodeproj
```

### 3. Try it in the simulator (no signing needed)

Pick an iPad simulator in the toolbar (for example *iPad Pro 11-inch* or *iPad Air*) and press **⌘R**; iPhone
simulators work too. In the simulator, *I/O > Keyboard > Connect Hardware Keyboard* lets you try the ⌘ shortcuts. The simulator uses
`http://localhost:8000` automatically. "Scan a page" opens the photo picker there: drag a photo of sheet music onto
the simulator window first to put it in its Photos library.

### 4. Run it on your iPad (or iPhone)

1. Plug the iPad in (or pair it over Wi-Fi in Xcode's *Devices* window). On the phone, turn on
   **Settings > Privacy & Security > Developer Mode** if asked (iOS 16+), then restart it.
2. In Xcode, click the **MusicScan** project in the left sidebar, then the **MusicScan** target, then
   **Signing & Capabilities**. Choose your **Team** (sign in with your Apple ID under *Add an Account…*; a free
   account works). If Xcode says the bundle identifier is taken, change `com.example.musicscan` to something of
   your own, such as `com.yourname.musicscan`.
3. Optional: build in a default server. From the repo root run
   `scripts/use_server.sh <address> [key]` (for example your Mac's `http://192.168.1.20:8000`, or the hosted
   server and its key). It writes `ios/Secrets.xcconfig`, which is gitignored and read by `ios/Config.xcconfig`.
   You can also just type the address in the app.
4. Pick your iPad in the toolbar and press **⌘R**.
5. The first launch on the phone: if it says the developer is not trusted, go to
   **Settings > General > VPN & Device Management**, tap your Apple ID and **Trust**. Open the app again and tap
   **Allow** when it asks to find devices on your local network.
6. If it can't reach the server, tap **Change server**, enter `http://<your Mac's IP>:8000`, **Test connection**,
   **Save**. The phone and Mac must be on the same Wi-Fi.

A free Apple ID signs the app for 7 days; after that, press ⌘R again. A paid developer account signs it for a year
and allows TestFlight.

### Debugging the editor on the phone

The web view is inspectable: on the Mac open Safari > Settings > Advanced > *Show features for web developers*, then
**Develop > [your iPad] > MusicScan** for the console, network and element inspector.

## What's in here

```
ios/
  MusicScan.xcodeproj         Xcode project (one app target, iOS 16+, iPhone and iPad)
  MusicScan/
    MusicScanApp.swift        app entry; audio session so playback ignores the silent switch
    ContentView.swift         web view + "can't reach the server" screen
    EditorWebView.swift       WKWebView and the bridge: scan, share, haptic, settings
    ServerConfig.swift        server address (default from Info.plist, filled from Config.xcconfig + Secrets.xcconfig)
    ServerSettingsView.swift  address sheet with a connection test
    Info.plist                camera and local-network permission texts, http allowed for the dev server
    Assets.xcassets           icon, launch color
```

The web side of the bridge is [`web/js/native.js`](../web/js/native.js); in a normal browser it does nothing, so the
web app is unchanged. `tests/ipad.js` checks iPad layouts, Apple Pencil and the ⌘ commands; `tests/touch.js` runs the editor on an emulated iPhone with a fake bridge (drag, swap, add,
export via the share sheet).

## Apple Pencil markup: what to check on a real iPad

Ink mode (✏ Ink, ⌘3) draws with the Pencil through WebKit pointer events (`pointerType: "pen"`, pressure, coalesced
points); fingers keep scrolling once a Pencil has drawn. Pencil double-tap in Ink mode swaps pen and eraser. Only the
⌘3 key command changed on the Swift side. Worth checking by hand, since the cloud tests emulate the Pencil:
- strokes follow the tip without lag on a ProMotion iPad, and a quick flick does not scroll the page;
- Scribble (iPadOS handwriting) does not grab the Pencil over the score (Settings > Apple Pencil > Scribble);
- a finger scrolls in Ink mode after the Pencil has drawn, and a palm on the screen does not leave marks.

## Handing off to another agent

[AGENT_PROMPT.md](AGENT_PROMPT.md) is a ready-to-paste prompt for Claude Code on your Mac to continue in Xcode.

## Known limits of the prototype

- Needs the server on the same network; no hosted server, accounts or offline reading yet.
- Only the first page of a multi-page document-camera scan is read (the app says so).
- `NSAllowsArbitraryLoads` is on so the app can talk to a plain-http dev server. Turn it off once the server has https.
- Not yet built in CI: this repo's cloud environment has no Xcode, so the Swift code has been reviewed but compiled
  only on your Mac. If Xcode shows an error, paste it into the project thread.
