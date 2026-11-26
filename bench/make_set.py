"""Ground-truth set: music21 corpus excerpts that fit one page, rendered with Verovio.

  python bench/make_set.py bench/data
Writes <id>.musicxml (ground truth for exactly what is on the page) and <id>.png (clean render)."""
from __future__ import annotations

import json
import sys
from pathlib import Path

import cairosvg
import music21 as m21
import verovio

PIECES = [  # (id, corpus path, part index or None for full score, max measures)
    ("bach_bwv66", "bach/bwv66.6", None, 24),
    ("bach_bwv269", "bach/bwv269", None, 24),
    ("bach_bwv1_6", "bach/bwv1.6", None, 24),
    ("mozart_k545", "mozart/k545/movement1_exposition", None, 20),
    ("clara_polonaise", "schumann_clara/polonaise_op1n1", None, 16),
    ("joplin_rag", "joplin/maple_leaf_rag", None, 16),
    ("mozart_k80_vn1", "mozart/k80/movement1", 0, 40),
    ("haydn_74_vn1", "haydn/opus74no1/movement1", 0, 40),
    ("beethoven_18_vc", "beethoven/opus18no1/movement1", 3, 40),
    ("weber_clarinet", "weber/concertino_clarinet", 0, 40),
    ("mozart_k458_quartet", "mozart/k458/movement1", None, 16),
    ("handel_lascia", "handel/rinaldo/Lascia_chio_pianga", None, 20),
]

OPTS = {"pageWidth": 2100, "pageHeight": 2970, "scale": 45, "adjustPageHeight": False, "footer": "none",
        "header": "none", "breaks": "auto", "pageMarginLeft": 120, "pageMarginRight": 120,
        "pageMarginTop": 120, "pageMarginBottom": 120}


def render(xml_path: Path, png: Path, width=2000) -> int:
    tk = verovio.toolkit()
    tk.setOptions(OPTS)
    tk.loadFile(str(xml_path))
    n = tk.getPageCount()
    if n == 1:
        cairosvg.svg2png(bytestring=tk.renderToSVG(1).encode(), write_to=str(png), output_width=width,
                         background_color="white")
    return n


def main(out: Path):
    out.mkdir(parents=True, exist_ok=True)
    meta = []
    for pid, path, part, maxm in PIECES:
        s = m21.corpus.parse(path)
        if part is not None:
            p = s.parts[part]
            s = m21.stream.Score([p])
        for el in list(s.recurse().getElementsByClass(("TextExpression", "RehearsalMark", "MetronomeMark"))):
            el.activeSite.remove(el)
        n = maxm
        while n >= 4:
            ex = s.measures(0, n)
            xml = out / f"{pid}.musicxml"
            ex.write("musicxml", fp=str(xml))
            if render(xml, out / f"{pid}.png") == 1:
                break
            n -= 2 if n > 12 else 1
        meta.append({"id": pid, "source": path, "part": part, "measures": n})
        print(pid, n, flush=True)
    (out / "index.json").write_text(json.dumps(meta, indent=1))


if __name__ == "__main__":
    main(Path(sys.argv[1] if len(sys.argv) > 1 else "bench/data"))
