# MusicScan "Sky" design

The light blue design system and wireframes for MusicScan. The web app in `web/` already follows it. Use this folder as the reference for the native iPad and iPhone apps.

Live canvas (private, with comments): https://claude.ai/artifact/CQ5niYBhsneZSpYNWz1ddn

## What is here

| Path | What it is |
|---|---|
| `wireframes/*.html` | The 14 canvas artboards as standalone HTML pages. Open one in any browser. The links between screens work. |
| `wireframes/*.png` | The same artboards as 2x images. |
| `screens/*.png` | Screenshots of the screens as built in the web app (iPad Pro 11 landscape and iPhone 14). |
| `tokens.json` | Colours, flag colours, fonts, radii, sizes and shadows. Same values as `:root` in `web/style.css`. |
| `source/` | The canvas sources (`*.dc.html`, `canvas.json`) and `export.js`, which rebuilds `wireframes/` from them. |

Artboards: Main (the design system sheet), iPad 1 Welcome, 2 Library, 3 Capture and photo check, 4 Reading (loading), 5 Editor with flags and ink, 6 Fix it, 7 Practice, 8 Paywall; iPhone 1 Library, 2 Capture, 3 Editor, 4 Practice, 5 Paywall. iPad landscape is 1194 x 834 and iPhone is 390 x 844.

## The rules in short

- **Colour.** Sky 25 background, white cards, Sky 50 bars. Blue 600 is the one primary colour. Sky 100 with Blue 700 text marks the selected item. Marigold is only for Pro and celebrations. The practice bar is the only dark surface (Navy 900).
- **Flags.** Each confidence flag has a colour and a shape, so it reads without colour too: sure is a green check, glance is an amber dot, likely wrong is a red triangle. Bars are tinted with the flag fill.
- **Type.** Titles use the rounded display face (SF Pro Rounded on Apple, Nunito as the web fallback) at weight 800 to 900. All other UI uses the system font.
- **Shape.** Corner radii are 10 for controls, 14 for buttons, 20 for cards and 28 for sheets. Touch targets are at least 44 pt.
- **Icons.** Original line icons with a 1.75 stroke and round caps. The logo is viewfinder corners around a note. All art is original and free to use commercially.
- **Rows as printed.** The editor keeps each system's bars on one row, as on the photo, and zooms to fit the widest row. Only the upright iPhone wraps rows.
- **Copy.** Short and plain: "Scan it. Fix it. Play it.", "2 bars to glance at", "Not now".

## Built in the web app

| Screen | Code | Test |
|---|---|---|
| Rows as printed | `web/js/render.js` (`SQUEEZE`, `fitZoom`), `S.autoZoom` in `web/js/app.js` | `tests/rows.js` |
| Live photo check | `web/js/capture.js` | `tests/capture.js` |
| Your music (library) | `web/js/library.js` | `tests/library.js` |
| Practice bar | `web/js/practicebar.js` | `tests/practicebar.js` |
| Paywall (UI only, off unless `?paywall`) | `web/js/paywall.js` (prices and copy in `PLAN`) | `tests/paywall.js` |

Run a test with `NODE_PATH=$(npm root -g) node tests/<name>.js`.

## Notes for iOS

- Capture on iOS should keep VisionKit's document camera. The live photo check in `capture.js` is for the web; its thresholds (sharpness, paper brightness, fill and motion) are a starting point if you add a check before upload.
- Plans (Allen, 2026-11-26): Pro $15.99 a month or $99.99 a year (default, "Best value"; no free trial, the 1 free page is the free offer), up to 30 pages a month. New users get 1 free page with every feature; after that a scan previews the first half of the page and blurs the rest, and editing, playback and export ask to unlock. No weekly plan. Payments are not connected yet (see docs/AGENT_PROMPTS.md, Stream 5).
- The paywall wireframes (iPad 8, iPhone 5) and the free-page notes on Welcome and Library match these plans. The paywall shots in `screens/` show the built sheet, and `half_page_preview_ipad.png` shows the blurred half-page preview. `PLAN` in `web/js/paywall.js` is the source of truth for prices and copy.
- On iPhone the editor puts durations in a bottom bar and the paywall is a bottom sheet. On iPad the photo sits beside the score.

## Assumptions to confirm

These choices were made without a review and are easy to change: the welcome copy, Yearly as the default plan, Marigold for Pro, and Nunito as the fallback for the rounded face.

## Rebuilding the wireframes

After editing the canvas, save its files into `source/` and run:

```
NODE_PATH=$(npm root -g) node design/sky/source/export.js design/sky/source "$PWD/design/sky/wireframes"
```
