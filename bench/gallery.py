"""Side-by-side examples from a finished benchmark run: the degraded input, what raw OMR read, and what the
MusicScan pipeline read, both re-engraved with the same Verovio settings as the ground truth.

  python bench/gallery.py bench/data bench/results out_dir [piece ...]
Writes one <piece>.png per piece (top part of the page only, so the images stay readable)."""
from __future__ import annotations

import io
import json
import sys
from pathlib import Path

import cairosvg
import verovio
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from make_set import OPTS  # noqa: E402
from musicscan.compare import compare  # noqa: E402

CONDS = ["clean", "photo", "shadow", "pen", "pencil", "combo", "lowq"]
LABEL = {"clean": "Clean scan", "photo": "Phone photo (warp, perspective, blur, noise)",
         "shadow": "Shadow and uneven light", "pen": "Red/blue pen markup", "pencil": "Pencil markup",
         "combo": "Warp + shadow + pen together", "lowq": "Blurry, dark, low-res photo"}
COL_W, TOP = 900, 0.36  # column width in px, fraction of the page shown


def font(size):
    for f in ["/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf"]:
        try:
            return ImageFont.truetype(f, size)
        except OSError:
            pass
    return ImageFont.load_default()


def engrave(xml: str) -> Image.Image | None:
    tk = verovio.toolkit()
    tk.setOptions(OPTS)
    if not tk.loadData(xml):
        return None
    png = cairosvg.svg2png(bytestring=tk.renderToSVG(1).encode(), output_width=2000, background_color="white")
    return Image.open(io.BytesIO(png)).convert("RGB")


def top(im: Image.Image | None) -> Image.Image:
    if im is None:
        return Image.new("RGB", (COL_W, int(COL_W * 1.414 * TOP)), "white")
    im = im.convert("RGB").crop((0, 0, im.width, int(im.height * TOP)))
    return im.resize((COL_W, int(im.height * COL_W / im.width)), Image.LANCZOS)


def verdict(gt: str, pred: str | None) -> str:
    if not pred:
        return "no output"
    c = compare(gt, pred)
    s = f"pitches {c['pitch_f1']*100:.1f}%, notes+rests {c['note_f1']*100:.1f}%"
    if c.get("bar_ok") is not None:
        bad = [i + 1 for i, ok in enumerate(c["bar_ok"]) if not ok]
        if not bad:
            s += ", identical"
        elif c["pitch_f1"] == 1:
            s += ", only rests differ"
        else:
            s += ", bar " + ", ".join(map(str, bad[:6])) + ("…" if len(bad) > 6 else "") + " differ"
    else:
        s += f", {c['pred_measures']} of {c['gt_measures']} bars"
    return s


def build(pid: str, data: Path, res: Path, out: Path):
    gt = (data / f"{pid}.musicxml").read_text()
    rows = []
    orig = top(Image.open(data / f"{pid}.png"))
    rows.append(("Original (ground truth, engraved from MusicXML)", [orig], [""]))
    for cond in CONDS:
        img = res / "images" / f"{pid}__{cond}.jpg"
        if not img.exists():
            continue
        cells, caps = [top(Image.open(img))], ["input photo"]
        for mode in ("raw", "musicscan"):
            p = res / "pred" / f"{pid}__{cond}__{mode}.musicxml"
            x = p.read_text() if p.exists() else None
            cells.append(top(engrave(x) if x else None))
            if mode == "raw" and not x and cond == "clean":
                caps.append("raw OMR: same as MusicScan on a clean scan")
            else:
                caps.append(("raw OMR: " if mode == "raw" else "MusicScan: ") + verdict(gt, x))
        rows.append((LABEL[cond], cells, caps))
    head, cap_h, gap = 46, 34, 24
    W = COL_W * 3 + gap * 4
    H = 70 + sum(head + r[1][0].height + cap_h + gap for r in rows)
    sheet = Image.new("RGB", (W, H), "white")
    d = ImageDraw.Draw(sheet)
    d.text((gap, 18), f"{pid}: input → raw OMR → MusicScan (top of page)", fill="black", font=font(30))
    y = 70
    for title, cells, caps in rows:
        d.text((gap, y + 8), title, fill=(30, 30, 30), font=font(26))
        y += head
        for i, (c, cap) in enumerate(zip(cells, caps)):
            x = gap + i * (COL_W + gap)
            sheet.paste(c, (x, y))
            d.rectangle((x, y, x + c.width - 1, y + c.height - 1), outline=(200, 200, 200))
            ok = "identical" in cap or "only rests" in cap or cap.startswith(("input", "raw OMR: same")) or not cap
            d.text((x, y + c.height + 6), cap, fill=(20, 110, 60) if ok else (150, 60, 20), font=font(22))
        y += cells[0].height + cap_h + gap
    out.mkdir(parents=True, exist_ok=True)
    sheet.save(out / f"{pid}.png", optimize=True)
    return out / f"{pid}.png"


if __name__ == "__main__":
    data, res, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    ids = sys.argv[4:]
    for pid in ids:
        print(build(pid, data, res, out))
