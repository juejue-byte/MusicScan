# MusicScan v1 spec (revised 2026-11-26)

Full version with the dependency audit and reasoning: https://claude.ai/artifact/SrprMA3VxhnWeZSvBctwdc

## Goal
A self-hostable web app (later iOS) that turns photos of **printed** sheet music (piano or one instrument; one or more
staves; treble, bass, alto, tenor clefs) into clean MusicXML, shows which bars are uncertain, lets the user fix them on
the staff or rescan them, plays them back and exports MusicXML / MIDI.

## Stack
| Layer | Choice | Notes |
| --- | --- | --- |
| OMR | copisteria 1.3.4 + copista-28m (copista-2m for fast mode and rescans) | Apache-2.0 code and weights; credit KobiMusic (NOTICE) |
| Server | FastAPI, background jobs with polling | `server/app.py` |
| Images | Pillow, `pi-heif` (decode only), `pypdfium2`, OpenCV headless | not `pillow-heif` (GPL x265 in wheels) |
| Cleanup | page lock (largest quadrilateral → perspective warp), colored-pen removal (HSV, relative to paper), shadow flattening (background division), all automatic | `musicscan/preprocess.py` |
| Confidence | per symbol: min probability over class / staff position / dots / accidental heads; per bar: count below 0.85; per photo: image checks + share of uncertain symbols | `musicscan/omr.py`, `quality.py` |
| Editor | VexFlow 4 drawing a live MusicXML DOM; edits patch `<note>` elements | `web/js/` |
| Playback | Web Audio look-ahead scheduler, bundled FluidR3 GM samples (12 instruments), synth fallback; practice panel: tempo, speed-up per loop, count-in, click, mute/solo/volume per hand or voice | `web/js/audio.js`, `web/js/practice.js` |
| Export | MusicXML from the DOM, MIDI written in the browser | no server round trip |
| Not used | homr, Audiveris (AGPL), OSMD (not needed) | |

## Core flows
1. **Upload**: drag/drop, file picker, phone camera, paste; samples on the start screen.
2. **Transcribe**: job → cleanup → OMR → confidence → editor. Typical 15–20 s CPU (28m), ~4 s fast mode.
3. **Quality warning**: banner good / check / retake with reasons (too small, blurry, dark, many uncertain symbols).
4. **Edit**: select + drag pitch, keyboard (↑↓, 1–6, `.`, ♭♮♯, R, Del), Add-notes mode with ghost preview, chords,
   undo/redo, bar-length check.
5. **Rescan**: selected bars → rows re-read from the cleaned page (second model, enlarged, high-contrast; or a close-up
   photo) → side-by-side comparison → splice (key/time/clef inherited; bar-count changes allowed with a warning).
6. **Play / export**: cursor follows the bar; starts at the selected bar; `.musicxml`, `.mid`.

## iOS plan
Server inference for v1; VisionKit document camera for capture; the same editor in a WKWebView inside a native
SwiftUI shell (`ios/`, chosen over Capacitor: four native features, no Node/CocoaPods; bridge in `web/js/native.js`). On-device OMR only after porting copista-2m to Core ML and the Python pipeline to Swift. Verovio is not used in
the app (LGPL static-linking question avoided).

## Deferred
Manual 4-corner adjustment UI, multi-page PDF, accounts and cloud storage, tie / tuplet / articulation editing,
handwritten music.
