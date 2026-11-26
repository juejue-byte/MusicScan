# MusicScan: prompts for parallel coding agents

Six agents can work at the same time without stepping on each other. Each one owns a set of files, has a short list
of jobs, and a clear "done". Start each agent in the repo folder (`cd MusicScan && claude`), paste the **shared
preamble** first, then that agent's **stream** section.

| # | Stream | Owns (may edit freely) | Runs where |
| --- | --- | --- | --- |
| 1 | iOS app (Xcode) | `ios/**` | Mac with Xcode |
| 2 | Photo to rows (page and row finding) | `musicscan/preprocess.py`, `musicscan/quality.py`, `bench/degrade.py`, `bench/photos/**` (new) | Mac or cloud |
| 3 | Reading quality (piano first) | `musicscan/omr.py`, `musicscan/sanitize.py`, `tests/test_reconcile.py`, `tests/test_sanitize.py` | Mac or cloud |
| 4 | Server, hosting, speed | `server/**`, `deploy/**`, `scripts/**`, `requirements.txt` | Mac or cloud |
| 5 | Plans and payments | `web/js/paywall.js`, `ios/MusicScan/Store*.swift` (new), `server/billing.py` (new), `docs/legal/**` (new) | Mac with Xcode |
| 6 | Web editor and practice | `web/**` except `web/js/paywall.js` | anywhere with Node + Playwright |

Shared files that several streams may need (`web/js/app.js`, `server/app.py`, `SPEC.md`, `README.md`,
`bench/REPORT.md`): keep edits there **small and local** (a hook, a route, a line in a table), pull right before
you edit, and push right after.

---

## Shared preamble (paste first, for every agent)

```text
You are working on MusicScan: an app that turns a photo of printed sheet music into a score you can fix on the
staff, play back and export (MusicXML, MIDI). Repo: https://github.com/juejue-byte/MusicScan (you are in its root).
The person you work for is Allen. He wants a really good MVP over perfection, and he is competing with Sheetly
(trysheetly.com, a scan-and-play practice app with no editor); MusicScan must clearly beat it on reading accuracy,
editing, playback and markup.

Product facts (do not change without asking Allen):
- iPad first (landscape, Apple Pencil, keyboard), iPhone second, web as well. One editor: the web app in web/,
  shown inside a native SwiftUI shell on iOS (WKWebView). Reading runs on the server (Python, copisteria).
- Scope: printed music only. Piano (treble + bass grand staff) and single-staff parts, row by row. Choir/SATB:
  keep what works, no new effort. Lyrics: skipped for now.
- Pricing: MusicScan Pro $15.99 a month or $99.99 a year (7-day free trial on the yearly plan, intro-offer
  eligible users only), up to 30 pages a month. New users get 1 free page with every feature. After that a scan
  shows the first half of the page and blurs the rest; editing, playback and export ask to unlock. Must follow
  Apple's App Review Guidelines (StoreKit in-app purchase, Restore Purchases, clear terms and privacy policy).
- Design: the "Sky" light blue system in design/sky/ (README.md is the entry point, tokens.json the values).
  Original code and art only; editor conventions follow familiar notation apps (MuseScore/Flat style).
- Licenses: every tool must be usable commercially. No AGPL/GPL (no homr, Audiveris, pillow-heif). Verovio is LGPL:
  never statically linked into the iOS app. Keep the visible credit "OMR by copisteria © KobiMusic (Apache-2.0)".

Read first: SPEC.md, README.md (editing cheatsheet, how it works), bench/REPORT.md (the scorecard), then the files
your stream owns.

Setup: scripts/setup.sh (Python 3.12+ venv, copisteria pinned, ~140 MB weights), scripts/run.sh (http://localhost:8000).
Browser tests: NODE_PATH=$(npm root -g) node tests/<name>.js [outDir] (Playwright; most serve web/ themselves).
Python tests: python -m pytest tests -q.

Working rules:
- Stay inside the files your stream owns. If you need a change elsewhere, make it as small as possible and say so
  in the commit message; if it is more than a few lines, stop and tell Allen which stream should own it.
- Allen approved pushing straight to main. Commit small, with a plain-English message saying what a user gets.
  Before every push: git pull --rebase origin main, re-run your tests, then push. Never force-push.
- Every change ships with a test or a measured number. Report results honestly: if something could not be
  verified (no device, no GPU), say so.
- When a number in bench/REPORT.md or SPEC.md changes because of your work, update that line.
- Finish with a short summary for Allen: what changed for the user, the numbers before and after, what is left.
```

---

## Stream 1: iOS app (Xcode)

```text
Your stream: the iOS app in ios/ (SwiftUI shell + WKWebView editor). You own ios/**. Read ios/README.md,
ios/AGENT_PROMPT.md (the detailed checklist: follow it), design/sky/README.md and the wireframes in
design/sky/wireframes/ (iPad 1194 x 834 and iPhone 390 x 844 artboards), web/js/native.js (the JS bridge).

Jobs, in order:
1. Make it compile with zero new warnings and run on an iPad Pro 11 simulator, then iPhone 15.
2. Point it at a server: local (HOST=0.0.0.0 scripts/run.sh) or the hosted one (deploy/README.md, ?key= access key).
3. Native chrome in the Sky look: start/library screen, capture (VisionKit document camera; multi-page scans add
   pages in order), reading progress, settings. Use tokens.json values and SF Pro Rounded for titles. The editor
   itself stays the web app.
4. Verify every flow on iPad (landscape, portrait, Split View, Stage Manager, hardware keyboard, Pencil) and
   iPhone: scan -> read -> Fix it -> edit by touch -> play (silent switch on) -> export via share sheet -> reopen
   from the library. Fix what feels wrong; web fixes go in web/ only if Stream 6 agrees (or keep them tiny).
5. Bundle web/ into the app (WKURLSchemeHandler) so the editor opens instantly and only api/ goes to the server.

Do not build StoreKit here: Stream 5 owns purchases (Store*.swift). Leave a clear hook for it in ContentView.

Done when: xcodebuild succeeds for iPad and iPhone simulators with no new warnings; a screen recording or
screenshots of each flow on iPad landscape and iPhone exist in ios/screens/; ios/README.md lists what was verified
on a real device and what was not.
```

## Stream 2: Photo to rows (page and row finding)

```text
Your stream: getting every row of music off a real phone photo before the reader sees it. You own
musicscan/preprocess.py, musicscan/quality.py, bench/degrade.py and a new bench/photos/ set. Today's weak spot:
on Sheetly's photo suite (bench/sheetly_compare.sh) MusicScan scored 79.1% strict F1 against 96.9% on clean pages,
and the gap is almost all pages where rows or bars were lost or split before reading (18 of 31 pages had the wrong
bar count). Pages with the right bar count read about 96%.

Jobs:
1. Reproduce: bench/sheetly_compare.sh --max-pages 1 (photo31) and list, per failing page, whether the page lock,
   the dewarp, the pen mask or the shadow flattening caused the lost rows (save the cleaned page.png for each).
2. Fix the causes with simple, robust steps: e.g. reject a page quad that cuts staff lines, fall back to the whole
   photo when the quad is doubtful, dewarp curved pages along staff lines, keep thin barlines in the pen mask.
3. The low-quality warning must stay reliable: 28 of 28 unusable photos rated "retake", none of the usable ones.
4. Add 20+ real phone photos of public-domain printed piano and single-staff pages to bench/photos/ (with MusicXML
   ground truth from music21 or IMSLP-free sources, and a LICENSE note per file), and report on them separately.

Users can already fix a bad page by hand ("Adjust edges": drag the four corners, POST /api/jobs/{id}/reread),
so the automatic path should prefer "leave the page whole" over "crop a row off".

Done when: photo31 strict F1 >= 94% with clean31 not lower than today (96.9%), retake detection still 28/28 with
0 false alarms, tests/test_pen_mask.py and a new tests/test_page_lock.py pass, bench/REPORT.md updated.
```

## Stream 3: Reading quality (piano first)

```text
Your stream: what happens after the reader, so fewer bars are wrong and the wrong ones are marked. You own
musicscan/omr.py (reconcile, second_opinion, levels) and musicscan/sanitize.py, plus their tests. Piano is the weak
spot: a typical 14-bar piano page has 3-4 wrong bars (missed chord notes, triplet signs on the wrong notes,
irregular runs read as sextuplets, a missed clef change). Today 51% of wrong bars are marked, 53% of marks are
real, 5% of correct bars get a mark.

Jobs:
1. bench/report.py on the saved results (bench/results, and pred2m for the second reading): list the piano error
   types by count. Pick the top two.
2. Fix them with checks that use what MusicScan already has: does each bar add up, do both readings agree, do the
   two hands line up in time, is a tuplet's total right. Prefer "mark the bar" over "silently change it" unless
   the benchmark shows the change is right at least 85% of the time.
3. Raise the share of wrong bars that are marked to 70% while keeping correct bars marked at 6% or less.

Do not touch preprocess.py (Stream 2) or the server routes (Stream 4).

Done when: piano note F1 >= 98% on the 28-piece benchmark with no other kind of page lower than today, the flag
numbers above are met, pytest passes, and the scorecard at the top of bench/REPORT.md is updated.
```

## Stream 4: Server, hosting and speed

```text
Your stream: the reading server and where it runs. You own server/**, deploy/**, scripts/** and requirements.txt.
Read deploy/README.md (Modal, GPU, access key) and server/app.py.

Jobs:
1. Speed: time each stage of a page (cleanup, main reading, second reading, sanitize) on CPU and on the Modal GPU,
   and cut the time to the first editable score. Keep the two readings' results identical; prove it on the
   benchmark (bench/run.py on a subset, same notes and flags before and after).
2. Reliability: job store survives restarts, old jobs and photos are deleted after 30 days, uploads over 40 MB
   or non-images are refused cleanly, one user cannot starve others (a queue with a per-user limit).
3. Accounts-light: an install id from the app is enough for page counting (Stream 5 needs it); no email login.
4. Previews: for a scan that is a half-page preview, the server returns only the bars of the first half (the blur
   must not be the only protection). Coordinate the flag name with Stream 5.

Done when: the deploy works from a clean Mac by following deploy/README.md; p50 time to an editable page is
measured and reported before/after in deploy/README.md; tests/test_access_key.py and new server tests pass.
```

## Stream 5: Plans and payments

```text
Your stream: turning the paywall UI into real purchases that pass App Review. You own web/js/paywall.js (the PLAN
object holds prices and copy), new ios/MusicScan/Store*.swift files, a new server/billing.py and docs/legal/.
Today the paywall is UI only and off unless the URL has ?paywall.

The plan (decided by Allen): Pro $15.99 a month or $99.99 a year, 7-day free trial on the yearly plan for
intro-offer eligible users, up to 30 pages a month. 1 free page with every feature for new users; after that a scan
previews the first half of the page and blurs the rest, and editing, playback and export ask to unlock.

Jobs:
1. StoreKit 2 in the iOS app: two auto-renewable subscriptions in one group, a StoreKit configuration file for the
   simulator, purchase, Restore Purchases, manage subscription, intro-offer eligibility for the trial badge.
   Pass the entitlement to the web editor through native.js (one small bridge message).
2. Server check: App Store Server API / signed transaction verification in server/billing.py; the page counter
   (30 a month) lives on the server keyed by the install id from Stream 4.
3. App Review: privacy policy and terms pages in docs/legal/ (fill PLAN.privacyUrl), clear price and renewal text
   on the paywall, no dark patterns, the free page really includes every feature.
4. Web: keep the paywall off on the web unless a flag is set; no card payments on the web for now.

Done when: a sandbox purchase, restore and trial work on a simulator with the StoreKit config; tests/paywall.js
passes; docs/legal/ has the two pages; a checklist of the relevant App Review guidelines (3.1.1, 3.1.2, 5.1.1) is
in docs/legal/REVIEW_CHECKLIST.md with each item ticked or explained.
```

## Stream 6: Web editor and practice

```text
Your stream: the editor, playback and markup in web/ (all of it except web/js/paywall.js). Read the editing
cheatsheet in README.md and the shortcut map (SHORTCUTS in web/js/app.js; A-G, R and 0-7 are reserved for note
input). Allen's rules: picking a length, rest or accidental turns the selection into that (no toggles); standard
undo/redo icons; MuseScore/Flat-style conventions; big touch targets on iPad; the iPad landscape toolbar has only
~5 px to spare (tests/markup.js checks it).

Jobs:
1. A fresh-eyes QA pass on iPad landscape and iPhone (Playwright device emulation): open each sample, fix every
   flagged bar with Fix it, add notes by touch, play with loop and parts, add marks and ink, export, reopen from
   Your music. File each rough edge as a fix with a test.
2. Speed of editing on a long piece (10 pages): every edit redraws in under 50 ms (tests/redraw_perf.js).
3. Practice: count-in, loop, tempo, hands are solid on iPad Safari; the practice bar never covers the bar being
   played.
4. Accessibility: every control has a label, contrast meets the Sky tokens, the flags read without colour.

Done when: every test in tests/*.js that runs without a server passes (list them in README.md "Tests"), new
fixes each have a test, and screenshots of the main screens are refreshed in design/sky/screens/.
```

---

## How Allen can check progress

- `git log --oneline origin/main` shows every agent's commits, each saying what a user gets.
- `bench/REPORT.md` (top table) is the scorecard; Streams 2 and 3 update it.
- `SPEC.md` says what the product does today; any stream that changes behaviour updates its line.
