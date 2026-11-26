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
    ("beethoven_18_viola", "beethoven/opus18no1/movement1", 2, 40),   # alto clef
    ("haydn_74_viola", "haydn/opus74no1/movement1", 2, 40),          # alto clef
    ("mozart_k458_quartet", "mozart/k458/movement1", None, 16),
    ("handel_lascia", "handel/rinaldo/Lascia_chio_pianga", None, 20),
    # set 2 (2026-11-26): songs with piano, more keyboard, chorales, more string and quartet parts
    ("schubert_lindenbaum", "schubert/Lindenbaum", None, 16),               # voice + piano, 3 staves
    ("schumann_dichterliebe2", "schumann_robert/dichterliebe_no2", None, 16),
    ("johnson_lift", "johnson_j_r/lift_every_voice", None, 12),
    ("cpebach_h186", "cpebach/h186", None, 20),                             # keyboard
    ("chopin_mazurka", "chopin/mazurka06-2.krn", None, 20),
    ("schoenberg_op19", "schoenberg/opus19/movement2", None, 9),
    ("corelli_trio", "corelli/opus3no1/1grave", None, 16),                  # trio sonata, 3 to 4 staves
    ("schumann_op41_quartet", "schumann_robert/opus41no1/movement1", None, 14),
    ("bach_bwv7_7", "bach/bwv7.7", None, 24),
    ("bach_bwv10_7", "bach/bwv10.7", None, 24),
    ("beethoven_59_vn1", "beethoven/opus59no1/movement1", 0, 40),
    ("beethoven_59_2_vc", "beethoven/opus59no2/movement1", 3, 40),
    ("haydn_1_viola", "haydn/opus1no1/movement1", 2, 40),                  # alto clef
    ("mozart_k155_vn2", "mozart/k155/movement1", 1, 40),
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
    only = set(sys.argv[2].split(",")) if len(sys.argv) > 2 else None
    for pid, path, part, maxm in PIECES:
        if only and pid not in only:
            continue
        try:
            s = m21.corpus.parse(path)
        except Exception as e:  # a corpus file this music21 version can't read
            print(pid, "skipped:", e, flush=True)
            continue
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
    idx = out / "index.json"
    old = [m for m in json.loads(idx.read_text())] if idx.exists() and only else []
    keep = {m["id"] for m in meta}
    idx.write_text(json.dumps([m for m in old if m["id"] not in keep] + meta, indent=1))


if __name__ == "__main__":
    main(Path(sys.argv[1] if len(sys.argv) > 1 else "bench/data"))
