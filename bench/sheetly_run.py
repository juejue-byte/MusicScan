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
Also per piece: what kind of mistakes were left (missed notes, extra notes, wrong pitch, wrong length, wrong beat).

  --max-pages 1     quick run: page one of each piece only (minutes instead of an hour)
  --fast            the small detector and no second reading (about 3x faster, a little less accurate, no red marks)
Engraved pages are cached in <out>/pages, and a run that is stopped resumes where it left off (results.json).
Writes <out>/results.json and prints a table."""
from __future__ import annotations

import argparse
import io
import json
import time
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
    try:
        verovio.enableLog(False)       # it prints a warning for every unsupported MusicXML element otherwise
    except Exception:
        pass
    tk = verovio.toolkit()
    tk.setOptions(OPTS)
    tk.loadFile(str(xml_path))
    out = []
    for p in range(1, tk.getPageCount() + 1):
        svg = tk.renderToSVG(p)
        n = svg.count('class="measure"')
        out.append((cairosvg.svg2png(bytestring=svg.encode(), output_width=2000, background_color="white"), n))
    return out


def cached_pages(cache: Path, xml_path: Path) -> list[tuple[bytes, int]]:
    """engrave_pages, kept on disk so a second run (or a resumed one) doesn't render again."""
    meta = cache / "bars.json"
    if meta.exists():
        bars = json.loads(meta.read_text())
        files = [cache / f"p{i}.png" for i in range(1, len(bars) + 1)]
        if all(f.exists() for f in files):
            return [(f.read_bytes(), n) for f, n in zip(files, bars)]
    pages = engrave_pages(xml_path)
    cache.mkdir(parents=True, exist_ok=True)
    for i, (png, _) in enumerate(pages, 1):
        (cache / f"p{i}.png").write_bytes(png)
    meta.write_text(json.dumps([n for _, n in pages]))
    return pages


def breakdown(gt: list, pred: list) -> dict:
    """What kind of mistakes are left, counted per note, bar by bar. Events are (bar, onset, midi, length, ...) as
    the scorer makes them. A missing note that has a note at the same beat in the reading is a wrong pitch or a wrong
    length; one with the same pitch elsewhere in the bar is a wrong beat; anything else is missed (or extra)."""
    from collections import defaultdict
    close = lambda a, b: abs(a - b) <= 0.0625  # noqa: E731  (their tolerance)
    by_bar = defaultdict(lambda: ([], []))
    for e in gt:
        by_bar[e[0]][0].append(e)
    for e in pred:
        by_bar[e[0]][1].append(e)
    out = {"right": 0, "missed": 0, "extra": 0, "pitch": 0, "length": 0, "beat": 0}
    for g, p in by_bar.values():
        g, p = list(g), list(p)
        for test, kind in ((lambda a, b: a[2] == b[2] and close(a[1], b[1]) and close(a[3], b[3]), "right"),
                           (lambda a, b: a[2] == b[2] and close(a[1], b[1]), "length"),
                           (lambda a, b: close(a[1], b[1]) and close(a[3], b[3]), "pitch"),
                           (lambda a, b: a[2] == b[2], "beat")):
            for a in list(g):
                b = next((b for b in p if test(a, b)), None)
                if b is not None:
                    g.remove(a)
                    p.remove(b)
                    out[kind] += 1
        out["missed"] += len(g)
        out["extra"] += len(p)
    return out


def read_page(png: bytes, fast: bool = False):
    """The app's pipeline on one page: cleanup, OMR, second opinion, sanitizer. Returns (xml, levels)."""
    from PIL import Image
    from musicscan import omr, preprocess
    from server.app import _clean
    pre = preprocess.preprocess(Image.open(io.BytesIO(png)).convert("RGB"))
    r = omr.transcribe(pre["image"], detector="2m" if fast else "28m")
    if not fast:
        omr.second_opinion(r, pre["image"])
    _clean(r)
    return r["xml"], [m["level"] for m in r["measures"]]


_POOL = None


def read_page_timed(png: bytes, timeout: float, fast: bool = False):
    """read_page in a worker process, so a page that hangs is abandoned after `timeout` seconds."""
    import concurrent.futures as cf
    import multiprocessing as mp
    global _POOL
    if _POOL is None:
        _POOL = cf.ProcessPoolExecutor(max_workers=1, mp_context=mp.get_context("spawn"))
    fut = _POOL.submit(read_page, png, fast)
    try:
        return fut.result(timeout=timeout)
    except cf.TimeoutError:
        for p in list(getattr(_POOL, "_processes", {}).values()):
            p.kill()
        _POOL.shutdown(wait=False, cancel_futures=True)
        _POOL = None
        raise TimeoutError(f"no result after {timeout:.0f} s")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bench", help="clone of github.com/loveranmar/omr-benchmark")
    ap.add_argument("out")
    ap.add_argument("--images", default="", help="their page images: <suite>/<slug>/p<N>.png|jpg")
    ap.add_argument("--suites", default="clean31,photo31")
    ap.add_argument("--only", default="")
    ap.add_argument("--timeout", type=float, default=300, help="seconds per page before it is skipped")
    ap.add_argument("--max-pages", type=int, default=0, help="read only the first N pages of each piece (0 = all)")
    ap.add_argument("--fast", action="store_true", help="small detector, no second reading")
    a = ap.parse_args()
    bench, out = Path(a.bench), Path(a.out)
    sys.path.insert(0, str(bench))
    import photo_sim
    import score as S

    manifest = json.loads((bench / "manifest.json").read_text())
    tag = ("-fast" if a.fast else "") + (f"-p{a.max_pages}" if a.max_pages else "")
    res_path = out / f"results{tag}.json"
    results = json.loads(res_path.read_text()) if res_path.exists() else {}
    results = {k: v for k, v in results.items() if "errors" in v}   # rows from before the after-fix correction
    for suite in a.suites.split(","):
        spec = manifest["suites"][suite]
        gt_dir = bench / suite / "ground-truth"
        for piece in spec["pieces"]:
            slug = piece["slug"]
            key = f"{suite}/{slug}"
            if (a.only and slug not in a.only.split(",")) or key in results:
                continue
            gt_xml = (gt_dir / f"{slug}.musicxml").read_text(errors="ignore")
            print(f"{key}: preparing pages", flush=True)
            # pages: (image bytes, bars of ground truth on that page)
            if a.images:
                d = Path(a.images) / suite / slug
                pages = []
                for pg in piece["pages"]:
                    f = next((d / f"p{pg['page']}{e}" for e in (".png", ".jpg", ".jpeg") if (d / f"p{pg['page']}{e}").exists()), None)
                    if f:
                        pages.append((f.read_bytes(), pg["measures"]))
            else:
                pages = cached_pages(out / "pages" / suite / slug, gt_dir / f"{slug}.musicxml")
                if suite.startswith("photo"):
                    pages = [(photo_sim.degrade_png(png, "moderate", photo_sim.stable_seed(slug, i)), n)
                             for i, (png, n) in enumerate(pages, 1)]
            if a.max_pages:
                pages = pages[:a.max_pages]
            events, fixed, offset, bars_scanned, marked, nbars, skipped, mismatched = [], [], 0, 0, 0, 0, 0, 0
            gt_events = S.note_events(gt_xml)
            for pi, (png, n) in enumerate(pages, 1):
                t0 = time.time()
                print(f"  {key} page {pi}/{len(pages)} ({n} bars)...", end=" ", flush=True)
                try:
                    xml, levels = read_page_timed(png, a.timeout, a.fast)
                    pe = S.note_events(xml)
                    print(f"{len(levels)} bars read in {time.time() - t0:.0f} s", flush=True)
                except Exception as e:  # a page we could not read counts as empty (and is charged in full)
                    print(f"skipped: {e}", flush=True)
                    pe, levels = [], []
                    skipped += 1
                flagged = {i + 1 for i, lv in enumerate(levels) if lv != "ok"}
                marked += len(flagged)
                nbars += len(levels)
                # "after fixing": the user corrects every marked bar, which then holds exactly what the original
                # has there. Only possible to simulate when the page has as many bars as the original; on a page
                # with a missed or extra barline the bars don't line up, so it is left as read.
                aligned = len(levels) == n
                mismatched += not aligned
                for ev in pe:
                    events.append((offset + ev[0],) + tuple(ev[1:]))
                    if not aligned or ev[0] not in flagged:
                        fixed.append((offset + ev[0],) + tuple(ev[1:]))
                if aligned:
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
                "skipped_pages": skipped, "pages_bar_count_off": mismatched,
                "errors": breakdown(gt_win, events),
            }
            results[key] = row
            out.mkdir(parents=True, exist_ok=True)
            res_path.write_text(json.dumps(results, indent=1))
            print(key, row, flush=True)

    # tables
    print("\n| Suite | Pieces | Strict F1, all pages | After fixing marked bars | Page-one window | Bars marked |")
    print("| --- | --- | --- | --- | --- | --- |")
    for suite in a.suites.split(","):
        rows = [v for k, v in results.items() if k.startswith(suite + "/")]
        if not rows:
            continue
        m = lambda k: sum(r[k] for r in rows) / len(rows)  # noqa: E731
        print(f"| {suite} | {len(rows)} | {m('strict_f1'):.1%} | {m('after_fix'):.1%} | {m('page_one'):.1%} | "
              f"{sum(r['marked'] for r in rows) / max(sum(r['read_bars'] for r in rows), 1):.0%} |")

    print("\nNotes left wrong, per 100 notes of the original (all pieces in each suite together):\n")
    print("| Suite | Missed | Extra | Wrong pitch | Wrong length | Wrong beat |")
    print("| --- | --- | --- | --- | --- | --- |")
    for suite in a.suites.split(","):
        rows = [v["errors"] for k, v in results.items() if k.startswith(suite + "/") and "errors" in v]
        if not rows:
            continue
        t = {k: sum(r[k] for r in rows) for k in rows[0]}
        n = max(t["right"] + t["missed"] + t["pitch"] + t["length"] + t["beat"], 1)
        print(f"| {suite} | " + " | ".join(f"{100 * t[k] / n:.1f}" for k in ("missed", "extra", "pitch", "length", "beat"))
              + " |")
    worst = sorted(results.items(), key=lambda kv: kv[1]["strict_f1"])[:5]
    print("\nLowest pieces: " + ", ".join(f"{k} {v['strict_f1']:.1%}" for k, v in worst))


if __name__ == "__main__":
    main()
