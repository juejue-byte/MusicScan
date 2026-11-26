"""Run real phone photos through the same steps as the server (server/app.py _run) and make side-by-side sheets:
the photo, the cleaned page with every flagged bar boxed (red = likely wrong, amber = check), and MusicScan's
reading re-engraved with Verovio. If a true score is given, the reading is scored with musicscan.compare.

  python bench/real_photos.py OUT photo.jpg[=truth.musicxml] ...
Writes OUT/<name>/{original.jpg,page.png,result.musicxml,result.json} and OUT/<name>.png, plus OUT/summary.json."""
from __future__ import annotations

import io
import json
import sys
import time
from pathlib import Path

import cairosvg
import verovio
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "bench"))
from gallery import font  # noqa: E402
from musicscan import imageio, omr, preprocess  # noqa: E402
from musicscan.compare import compare  # noqa: E402
from musicscan.quality import assess  # noqa: E402
from server.app import _clean  # noqa: E402

COLORS = {"bad": (220, 40, 40), "check": (235, 150, 0)}
H = 1400  # height of each panel


def read(path: Path, d: Path) -> dict:
    data = path.read_bytes()
    im = imageio.load_image(data, path.name)
    im.save(d / "original.jpg", quality=90)
    t = time.time()
    import os
    raw = os.environ.get("RAW") == "1"
    pre = preprocess.preprocess(im, flatten=False if raw else None, strip_pen=not raw, lock_page=not raw, quad=None)
    pre["image"].save(d / "page.png")
    r = omr.transcribe(pre["image"], detector="28m")
    omr.second_opinion(r, pre["image"])
    _clean(r)
    q = assess(pre, r)
    r["seconds_total"] = round(time.time() - t, 1)
    (d / "result.musicxml").write_text(r["xml"])
    (d / "result.json").write_text(json.dumps({k: r[k] for k in ("measures", "systems", "stats", "seconds_total")}
                                              | {"quality": q, "steps": pre["steps"]}, default=str))
    r["quality"] = q
    return r


def engrave_all(xml: str) -> Image.Image | None:
    tk = verovio.toolkit()
    try:
        verovio.enableLog(False)
    except Exception:
        pass
    tk.setOptions({"pageWidth": 2100, "pageHeight": 2970, "scale": 40, "adjustPageHeight": True, "breaks": "encoded",
                   "footer": "none", "header": "none"})
    if not tk.loadData(xml):
        return None
    pages = []
    for p in range(1, tk.getPageCount() + 1):
        png = cairosvg.svg2png(bytestring=tk.renderToSVG(p).encode(), output_width=1600, background_color="white")
        pages.append(Image.open(io.BytesIO(png)).convert("RGB"))
    out = Image.new("RGB", (1600, sum(p.height for p in pages)), "white")
    y = 0
    for p in pages:
        out.paste(p, (0, y))
        y += p.height
    return out


def fit(im: Image.Image, h: int = H) -> Image.Image:
    im = im.convert("RGB")
    return im.resize((max(1, round(im.width * h / im.height)), h), Image.LANCZOS)


def flagged(page: Image.Image, measures: list) -> Image.Image:
    im = page.convert("RGB")
    d = ImageDraw.Draw(im, "RGBA")
    w = max(3, im.width // 400)
    for m in measures:
        c = COLORS.get(m.get("level"))
        x0, y0, x1, y1 = m["bbox"]
        d.rectangle((x0, y0, x1, y1), outline=(*c, 255) if c else (60, 140, 220, 90), width=w if c else 1,
                    fill=(*c, 40) if c else None)
        d.text((x0 + 4, y0 + 2), str(m["index"] + 1), fill=(40, 40, 40), font=font(max(14, im.width // 90)))
    return im


def sheet(name: str, r: dict, d: Path, caption: str) -> Path:
    cols = [("Phone photo", fit(Image.open(d / "original.jpg"))),
            ("Cleaned page, flagged bars (red = likely wrong, amber = check)",
             fit(flagged(Image.open(d / "page.png"), r["measures"]))),
            ("MusicScan's reading, re-engraved", None)]
    eng = engrave_all(r["xml"])
    if eng is not None:
        # long readings: keep the scale readable, cap at 2 panel heights
        s = min(1.0, 2 * H / eng.height)
        cols[2] = (cols[2][0], eng.resize((round(eng.width * s * 0.9), round(eng.height * s * 0.9)), Image.LANCZOS))
    else:
        cols[2] = (cols[2][0], Image.new("RGB", (900, H), "white"))
    gap, head = 30, 60
    W = sum(c[1].width for c in cols) + gap * (len(cols) + 1)
    Hh = 90 + head + max(c[1].height for c in cols) + 90
    out = Image.new("RGB", (W, Hh), "white")
    dr = ImageDraw.Draw(out)
    dr.text((gap, 20), name, fill="black", font=font(40))
    x = gap
    for title, im in cols:
        dr.text((x, 90), title, fill=(40, 40, 40), font=font(26))
        out.paste(im, (x, 90 + head))
        dr.rectangle((x, 90 + head, x + im.width - 1, 90 + head + im.height - 1), outline=(200, 200, 200))
        x += im.width + gap
    dr.text((gap, Hh - 70), caption, fill=(30, 30, 30), font=font(28))
    p = d.parent / f"{name}.png"
    out.save(p, optimize=True)
    return p


def main():
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    summ = {}
    for arg in sys.argv[2:]:
        photo, _, truth = arg.partition("=")
        photo = Path(photo)
        name = photo.stem
        d = out / name
        d.mkdir(exist_ok=True)
        r = read(photo, d)
        ms = r["measures"]
        lv = {k: sum(m.get("level") == k for m in ms) for k in ("ok", "check", "bad")}
        s = {"bars": len(ms), "rows": len(r.get("systems", [])), "levels": lv, "seconds": r["seconds_total"],
             "quality": r["quality"]}
        cap = f"{len(r.get('systems', []))} rows, {len(ms)} bars read; {lv['bad']} red, {lv['check']} amber; {r['seconds_total']} s"
        if truth:
            c = compare(Path(truth).read_text(), r["xml"])
            s["compare"] = {k: v for k, v in c.items() if not isinstance(v, list)}
            bok = c.get("bar_ok")
            if bok is not None:
                bad = [i + 1 for i, ok in enumerate(bok) if not ok]
                s["wrong_bars"] = bad
                flagged_set = {m["index"] + 1 for m in ms if m.get("level") in ("bad", "check")}
                s["wrong_and_flagged"] = sorted(set(bad) & flagged_set)
                s["wrong_unflagged"] = sorted(set(bad) - flagged_set)
            cap += (f"  |  vs true score: pitches {c['pitch_f1']*100:.1f}%, notes+rests {c['note_f1']*100:.1f}%, "
                    f"bars {c['pred_measures']}/{c['gt_measures']}")
            if bok is not None:
                cap += f", {len(s['wrong_bars'])} bars differ ({len(s['wrong_and_flagged'])} of them flagged)"
        s["sheet"] = str(sheet(name, r, d, cap))
        summ[name] = s
        print(name, json.dumps(s, default=str), flush=True)
        (out / "summary.json").write_text(json.dumps(summ, indent=1, default=str))


if __name__ == "__main__":
    main()
