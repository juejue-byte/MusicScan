"""Run MusicScan on Sheetly's public OMR benchmark and score it with their own strict-F1 scorer.

  git clone https://github.com/loveranmar/omr-benchmark ../omr-benchmark
  python bench/sheetly_run.py ../omr-benchmark bench/sheetly_out                 # re-render the pages ourselves
  python bench/sheetly_run.py ../omr-benchmark bench/sheetly_out --images DIR    # or use their page images

Their repository has the ground-truth MusicXML, every engine's output and the scorer (score.py, CC BY 4.0), but
not the page images (a separate download from trysheetly.com). Without --images, each ground-truth piece is
engraved with Verovio (every page) and the photo suite is made with their own photo_sim.py at "moderate". With
--images, DIR must hold <suite>/<slug>/p<N>.(png|jpg) as in their image bundle; check the layout first.

Scores per suite, with their scorer, over every page (not only page one):
  strict F1                 pitch, onset within the bar and length must all match (their headline metric)
  after fixing marked bars  the same, if the user corrects every bar MusicScan marked red or amber
  page-one window           only the first N bars, N = their page one, to compare with their published table
Writes <out>/<suite>/musicscan/<slug>.musicxml, <out>/results.json and prints a table."""
from __future__ import annotations

import argparse
import io
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))


def engrave_pages(xml_path: Path) -> list[tuple[bytes, int]]:
    """Verovio pages as PNG bytes, each with the number of bars on it."""
    import cairosvg
    import verovio
    sys.path.insert(0, str(ROOT / "bench"))
    from make_set import OPTS
    tk = verovio.toolkit()
    tk.setOptions(OPTS)
    tk.loadFile(str(xml_path))
    out = []
    for p in range(1, tk.getPageCount() + 1):
        svg = tk.renderToSVG(p)
        n = svg.count('class="measure"')
        out.append((cairosvg.svg2png(bytestring=svg.encode(), output_width=2000, background_color="white"), n))
    return out


def read_page(png: bytes):
    """The app's pipeline on one page: cleanup, OMR, second opinion, sanitizer. Returns (xml, levels)."""
    from PIL import Image
    from musicscan import omr, preprocess
    from server.app import _clean
    pre = preprocess.preprocess(Image.open(io.BytesIO(png)).convert("RGB"))
    r = omr.transcribe(pre["image"])
    omr.second_opinion(r, pre["image"])
    _clean(r)
    return r["xml"], [m["level"] for m in r["measures"]]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bench", help="clone of github.com/loveranmar/omr-benchmark")
    ap.add_argument("out")
    ap.add_argument("--images", default="", help="their page images: <suite>/<slug>/p<N>.png|jpg")
    ap.add_argument("--suites", default="clean31,photo31")
    ap.add_argument("--only", default="")
    a = ap.parse_args()
    bench, out = Path(a.bench), Path(a.out)
    sys.path.insert(0, str(bench))
    import photo_sim
    import score as S

    manifest = json.loads((bench / "manifest.json").read_text())
    res_path = out / "results.json"
    results = json.loads(res_path.read_text()) if res_path.exists() else {}
    for suite in a.suites.split(","):
        spec = manifest["suites"][suite]
        gt_dir = bench / suite / "ground-truth"
        for piece in spec["pieces"]:
            slug = piece["slug"]
            key = f"{suite}/{slug}"
            if (a.only and slug not in a.only.split(",")) or key in results:
                continue
            gt_xml = (gt_dir / f"{slug}.musicxml").read_text(errors="ignore")
            # pages: (image bytes, bars of ground truth on that page)
            if a.images:
                d = Path(a.images) / suite / slug
                pages = []
                for pg in piece["pages"]:
                    f = next((d / f"p{pg['page']}{e}" for e in (".png", ".jpg", ".jpeg") if (d / f"p{pg['page']}{e}").exists()), None)
                    if f:
                        pages.append((f.read_bytes(), pg["measures"]))
            else:
                pages = engrave_pages(gt_dir / f"{slug}.musicxml")
                if suite.startswith("photo"):
                    pages = [(photo_sim.degrade_png(png, "moderate", photo_sim.stable_seed(slug, i)), n)
                             for i, (png, n) in enumerate(pages, 1)]
            events, fixed, offset, bars_scanned, marked, nbars = [], [], 0, 0, 0, 0
            gt_events = S.note_events(gt_xml)
            for png, n in pages:
                try:
                    xml, levels = read_page(png)
                    pe = S.note_events(xml)
                except Exception as e:  # a page we could not read counts as empty
                    print(slug, "page failed:", e, flush=True)
                    pe, levels = [], []
                flagged = {i + 1 for i, lv in enumerate(levels) if lv != "ok"}
                marked += len(flagged)
                nbars += len(levels)
                for ev in pe:
                    events.append((offset + ev[0],) + tuple(ev[1:]))
                    if ev[0] not in flagged:
                        fixed.append((offset + ev[0],) + tuple(ev[1:]))
                # the user corrects a marked bar: it now holds exactly what the original has there
                fixed += [ev for ev in gt_events if offset < ev[0] <= offset + n and ev[0] - offset in flagged]
                offset += n
                bars_scanned += n
            events.sort()
            fixed.sort()
            gt_win = S.note_events(gt_xml, max_measures=bars_scanned)
            p1 = piece["pages"][0]["measures"]
            gt_p1 = S.note_events(gt_xml, max_measures=p1)
            row = {
                "strict_f1": S.score_pair(gt_win, events)["strict_f1"],
                "after_fix": S.score_pair(gt_win, fixed)["strict_f1"],
                "page_one": S.score_pair(gt_p1, [e for e in events if e[0] <= p1])["strict_f1"],
                "pages": len(pages), "bars": bars_scanned, "marked": marked, "read_bars": nbars,
            }
            results[key] = row
            out.mkdir(parents=True, exist_ok=True)
            res_path.write_text(json.dumps(results, indent=1))
            print(key, row, flush=True)

    # table
    print("\n| Suite | Pieces | Strict F1, all pages | After fixing marked bars | Page-one window | Bars marked |")
    print("| --- | --- | --- | --- | --- | --- |")
    for suite in a.suites.split(","):
        rows = [v for k, v in results.items() if k.startswith(suite + "/")]
        if not rows:
            continue
        m = lambda k: sum(r[k] for r in rows) / len(rows)  # noqa: E731
        print(f"| {suite} | {len(rows)} | {m('strict_f1'):.1%} | {m('after_fix'):.1%} | {m('page_one'):.1%} | "
              f"{sum(r['marked'] for r in rows) / max(sum(r['read_bars'] for r in rows), 1):.0%} |")


if __name__ == "__main__":
    main()
