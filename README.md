# MusicScan

Photograph printed sheet music, get a score you can **edit on the staff, play back, and export** as MusicXML or MIDI.
Web first, built so the same editor can ship inside an iOS app.

- **Upload** a phone photo, scan or PDF (JPG, PNG, HEIC, PDF). Tilted pages are flattened, colored pen marks are removed
  and shadows are evened out automatically.
- **Transcribe** with [copisteria](https://github.com/kobimusic/copisteria) (copista-28m, Apache-2.0), an open
  optical-music-recognition reader that also reports how sure it is about every symbol.
- **See what to check.** Bars the reader was unsure about are tinted on the score and on the photo, and a banner says
  when the photo itself is too blurry, dark or small to trust.
- **Edit on the staff.** Click a note and drag it up or down; arrows, number keys and ♭ ♮ ♯ for everything else;
  Add-notes mode writes new notes where you click, with a ghost preview of the pitch. Undo everything.
- **Rescan** a bad bar: re-read its row from the same photo another way, or from a close-up, compare old and new, keep
  the better one. Untouched bars keep their slurs, dynamics and beams.
- **Play** with a moving cursor and the sounding notes lit up (sampled piano), **export** `.musicxml` and `.mid`.

Scope of the MVP: printed music, piano or a single instrument, one or more staves, treble / bass / alto / tenor clefs.

## Run it

```bash
scripts/setup.sh     # venv, Python deps, copisteria (pinned) and its weights (~140 MB)
scripts/run.sh       # http://localhost:8000
```

Python 3.12+. A page takes about 15–20 s on a 4-core CPU with copista-28m and about 4 s in fast mode (copista-2m);
the GPU is used automatically when present (NVIDIA CUDA, or MPS on Apple Silicon Macs, with a CPU fallback for any op MPS
lacks). Force a device with `MUSICSCAN_DEVICE=cpu|mps|cuda scripts/run.sh`. Sample photos are on the start screen.

## Editing cheatsheet

| Do this | How |
| --- | --- |
| Change a pitch | Drag the note up/down, or select it and press ↑ ↓ (Shift: octave) |
| Reorder | Drag a note left/right past its neighbour to swap them |
| Change a duration | Select, then 1 whole · 2 half · 3 quarter · 4 eighth · 5 16th · 6 32nd · `.` dot |
| Accidentals | `-` flat · `=` natural · `+` sharp (or the ♭ ♮ ♯ buttons) |
| Write notes | **Add notes** (N), pick a duration, click on the staff. Clicking a rest fills it; following rests make room |
| Chords | In Add mode, Shift-click on an existing note |
| Note ↔ rest, delete | R · Delete |
| Wrong key or meter | **Key / time** (notes that followed the misread key are re-spelled) |
| Select bars | Click a bar number (Shift-click for a range), or a bar on the photo |
| Rescan | Select bars → **Rescan bars** → compare → keep or try another way |
| Play / stop | Space (starts at the selected bar) |
| Undo / redo | Ctrl/Cmd+Z · Ctrl/Cmd+Shift+Z |

Bars that no longer add up are outlined in red dashes and listed in the status bar.

## How it works

```
photo ─► clean up (page lock, pen removal, shadow flattening; musicscan/preprocess.py)
      ─► copisteria (symbols + context model → MusicXML + per-symbol probabilities; musicscan/omr.py)
      ─► confidence per bar + photo-quality verdict (musicscan/quality.py)
      ─► browser editor: VexFlow drawing a live MusicXML DOM (web/js/score.js, render.js, app.js)
```

The editor never rebuilds the MusicXML from a simplified model: every edit patches the `<note>` elements in place, so
everything it does not touch survives export. Rescans splice whole `<measure>` contents back in, keeping the key, time
and clef of the surrounding score.

## Benchmark

`bench/` renders ground-truth MusicXML from the music21 corpus with Verovio, turns each page into realistic phone
photos (tilt, desk background, shadow, colored pen, pencil, blur), runs raw OMR and the MusicScan pipeline, and scores
the result note by note against the original. Results and method: [bench/REPORT.md](bench/REPORT.md).

```bash
python bench/make_set.py bench/data          # ground truth + clean renders
python bench/run.py bench/data bench/results # ~140 OMR runs, resumable
python bench/report.py bench/results         # tables + quality-flag check
```

## Tests

```bash
python -m pytest tests -q            # Python: scoring, cleanup, OMR smoke test
node tests/e2e.js http://localhost:8000/ /tmp/e2e   # browser: upload → edit → rescan → play → export
```

## iOS

A prototype app is in [`ios/`](ios/README.md): a small SwiftUI shell that scans pages with Apple's document camera,
runs the same editor in a WKWebView (finger dragging with haptic ticks, Add-notes under your finger), plays through
the silent switch and exports through the share sheet. Reading still happens on the MusicScan server. Build steps:
[ios/README.md](ios/README.md); start the server with `HOST=0.0.0.0 scripts/run.sh` so the phone can reach it.

## Layout

```
musicscan/   Python: image decoding, cleanup, OMR wrapper, confidence, scoring
server/      FastAPI app (jobs, rescan, static web app)
web/         the app: index.html, style.css, js/ (score model, renderer, editor, audio), vendor/
bench/       benchmark: ground truth, degradations, runner, report
tests/       pytest + Playwright end-to-end (tests/touch.js: iPhone touch editing)
ios/         iOS app shell (SwiftUI + WKWebView)
scripts/     setup.sh, run.sh
```

## Licenses

MusicScan builds on copisteria by KobiMusic (Apache-2.0); see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
