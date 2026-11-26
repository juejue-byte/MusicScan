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
- **Fix it.** Steps through the flagged bars one at a time: plays the bar, shows it from your photo beside the
  reading (and beside the second model's reading when the two disagreed), says why it was flagged, and offers
  one-tap Looks right, Edit, Rescan or Second reading, with "3 of 7 checked" progress.
- **Rescan** a bad bar: re-read its row from the same photo another way, or from a close-up, compare old and new, keep
  the better one. Untouched bars keep their slurs, dynamics and beams.
- **Multi-page scores.** Add pages one photo at a time, or open a whole PDF (or a multi-page scan in the iOS app):
  every page lands in one score with straight-through bar numbers, and the time signature, key, clefs and part
  layout carry across page turns. Reorder, retake or remove pages; the photo panel, flags and rescans work per page.
- **Play** with a moving cursor and the sounding notes lit up (sampled piano), **export** `.musicxml` and `.mid`.

Scope of the MVP: printed music, piano or a single instrument, one or more staves, treble / bass / alto / tenor clefs.

## Run it

```bash
scripts/setup.sh     # venv, Python deps, copisteria (pinned) and its weights (~140 MB)
scripts/run.sh       # http://localhost:8000
```

Python 3.12+. A page takes about 9–12 s on a 4-core CPU with copista-28m for a scan or a flat, well-lit photo (both readings included), about 15–20 s for a harder photo, and about 4 s in fast mode (copista-2m);
the GPU is used automatically when present (NVIDIA CUDA, or MPS on Apple Silicon Macs, with a CPU fallback for any op MPS
lacks). Force a device with `MUSICSCAN_DEVICE=cpu|mps|cuda scripts/run.sh`. Sample photos are on the start screen.

## Host it (HTTPS + GPU, for the phone app anywhere)

`modal deploy deploy/modal_app.py` puts the reader on a public `https://…modal.run` address with a GPU and an access
key. Steps, costs and where the iOS app takes the address: [deploy/README.md](deploy/README.md).

## Preview without a server

`web/` also works on any static host (GitHub Pages, Cloudflare Pages, a plain file server). When no MusicScan server
answers, the sample photos open results the real reader produced earlier (`web/demo/`, built by
`scripts/build_demo.py`), and editing, rescans of the samples, playback and export all work. Reading new photos needs
the server. Force it with `?demo`.

## Editing cheatsheet

| Do this | How |
| --- | --- |
| Change a pitch | Drag the note up/down; or select it and type its letter A–G (moves on to the next note); ↑ ↓ semitone · Alt+↑ ↓ scale step · ⌘/Ctrl+↑ ↓ octave. On selected bars they move every note. iPad: tap the note, then a key on the piano (**Keyboard** button) |
| Reorder | Drag a note left/right past its neighbour to swap them |
| Change a duration | Select, then 7 whole · 6 half · 5 quarter · 4 eighth · 3 16th · 2 32nd · `.` dot (MuseScore / Dorico numbering) |
| Accidentals | `-` flat · `=` natural · `+` sharp (or the ♭ ♮ ♯ buttons) |
| Write notes | **Add notes** (N) puts a blue caret at the selection. Type A–G (nearest octave), 0 rest, R repeat, ← → move the caret, Backspace steps back. Or click / tap the staff, or the on-screen piano on iPad. Typing past the end adds a bar |
| Chords, voices, staves | Shift+A–G (or Shift-click, or **+ Chord** on the piano) adds a chord tone · ⌘⌥1–4 or **Voice 2** writes a second melody on the staff · ⌘⇧↑ ↓ moves a note to the other piano staff · ⌥⇧↑ ↓ or **Lower/Upper** moves the caret |
| Note ↔ rest, delete | 0 · Delete |
| Copy and paste | ⌘/Ctrl+C X V: a note or chord, or whole bars (also in **Bar ▾**). Shift+← → grows the bar selection, ⌘A selects all |
| Slurs, articulations | S slur · Shift+S staccato · Shift+V accent · Shift+N tenuto · Shift+O marcato (again removes it), or **Marks ▾** |
| Wrong key, meter or clef; transpose | **Key / time** (notes that followed the misread key are re-spelled; a misread clef keeps the notes where they are printed). Transpose the whole piece there too |
| Select bars | Click a bar number (Shift-click for a range), or a bar on the photo |
| Rescan | Select bars → **Rescan bars** → compare → keep or try another way |
| Check the flagged bars | **Fix it** (F): Enter looks right · `]` `[` next / previous flag · P play the bar · E edit it · Esc close. iPad keyboard: ⌘] ⌘[ ⌘⇧↵ ⌘⇧F |
| More pages | **Pages** (or **+ Page** over the photo): add a photo or PDF, reorder, retake, remove. Tabs 1 2 3 switch the photo |
| Play / stop | Space (starts at the selected bar) |
| Loop | L or ⟲: the selected bars repeat (nothing selected: the whole piece) |
| Dynamics, hairpins, fingering, text, rehearsal marks | Select a note (or bars), then **Marks ▾** (K). Tap a marking to select it; Delete removes it |
| Draw on the score | **Ink** (P): Apple Pencil, mouse or finger. Pens, highlighter, eraser (X, or Pencil double-tap). Ink never changes the notes |
| Show / hide ink | **Ink: shown / hidden** in the status bar |
| Undo / redo | Ctrl/Cmd+Z · Ctrl/Cmd+Shift+Z |
| Zoom | Pinch on iPad · ⌘/Ctrl+scroll · − + in the status bar |
| Every shortcut | ? |

Bars that no longer add up are outlined in red dashes and listed in the status bar.

**Markings are real MusicXML.** Dynamics, hairpins (`<wedge>`), fingerings, text (`<words>`) and rehearsal marks are
written as standard elements, so Finale, Sibelius, Dorico and MuseScore read them, and markings already in a file or
read from the photo are drawn too. **Ink** is a separate layer: it is saved inside the MusicXML as JSON in
`<identification><miscellaneous><miscellaneous-field name="musicscan-ink">`, so it is undone, exported and reopened
with the score while other apps simply ignore it. Each stroke is pinned to its bar and follows it when the score
reflows, or when bars are split, joined, inserted or deleted. Tests: `node tests/markup.js [outDir]`.

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
node tests/review.js /tmp/review        # browser (demo data, no server): the Fix it flow on iPad and iPhone
node tests/pages.js                               # multi-page: join, reorder, remove pages (no server)
node tests/multipage_e2e.js two-pages.pdf page.png  # multi-page end to end against the server
```

## iOS

A prototype app, iPad first (iPhone too), is in [`ios/`](ios/README.md): a small SwiftUI shell that scans pages with
Apple's document camera, supports Apple Pencil and ⌘ keyboard shortcuts,
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
