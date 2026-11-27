# MusicScan native iOS wireframes

Native iPad (landscape first) and iPhone screens for replacing the web view in the iOS app. Built on the Sky design
system in `design/sky/` with iOS 26 conventions: split views, sheets, floating glass toolbars, SF Symbols.

Live canvas (private, with comments): https://claude.ai/artifact/Pow6gYwDqCR1P58MCroT4b

| Path | What it is |
|---|---|
| `HANDOFF.md` | A short SwiftUI note per screen, to paste to the Xcode agent. Start with "Shared rules". |
| `wireframes/*.png` | Each screen as a 2x image. |
| `wireframes/*.html` | Each screen as a standalone page; links between screens work. |
| `assets/` | The engraved music (Verovio, from `bench/data/mozart_k545.musicxml` and other bench files, all public domain) and the fake phone photos (`bench/degrade.py`). |
| `source/` | Canvas sources (`*.dc.html`, `canvas.json`), `assets.json` (canvas asset id to file) and `export.js`. |

Screens: App map; iPad 1 Welcome, 2 Sign in, 3 Library, 4 Scan, 5 Photo check, 6 Edit, 7 Fix it, 8 Practice,
9 Export, 10 Paywall, 11 Settings; iPhone Library, Scan, Edit, Practice, Paywall.

Rebuild the standalone pages and PNGs after editing `source/`:

```
NODE_PATH=$(npm root -g) node design/native/source/export.js design/native/source "$PWD/design/native/wireframes"
```
