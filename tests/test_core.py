"""Fast checks of the Python side. Run: python -m pytest tests -q   (OMR test is skipped without weights)."""
import sys
from pathlib import Path

import numpy as np
import pytest
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "bench"))

from degrade import degrade  # noqa: E402

from musicscan import omr, preprocess  # noqa: E402
from musicscan.compare import compare, parse  # noqa: E402

DATA = ROOT / "bench" / "data"
GT = DATA / "mozart_k545.musicxml"


def clean_render():
    png = DATA / "mozart_k545.png"
    if not png.exists():
        pytest.skip("run bench/make_set.py first to render the benchmark pages")
    return np.asarray(Image.open(png).convert("RGB"))


def test_compare_identity():
    x = GT.read_text()
    r = compare(x, x)
    assert r["note_f1"] == 1.0 and r["ser"] == 0.0 and r["key_ok"] and r["time_ok"]


def test_compare_detects_wrong_pitch():
    x = GT.read_text()
    y = x.replace("<step>C</step>", "<step>D</step>", 3)
    r = compare(x, y)
    assert r["pitch_f1"] < 1.0


def test_parse_streams_piano():
    p = parse(GT.read_text())
    assert len(p["streams"]) == 2 and p["measures"] >= 10


def test_page_lock_finds_tilted_page():
    rgb = degrade(clean_render(), "photo", seed=3)
    q = preprocess.find_page(rgb)
    assert q is not None
    out = preprocess.preprocess(Image.fromarray(rgb))
    assert "page-flatten" in out["steps"]


def test_pen_marks_removed():
    rgb = degrade(clean_render(), "pen", seed=4)
    before = preprocess.pen_mask(rgb).mean()
    out = np.asarray(preprocess.preprocess(Image.fromarray(rgb))["image"])
    assert before > 0.001
    # colored ink is gone; black notation is still there
    assert (out < 100).mean() > 0.01


def test_clean_scan_untouched():
    out = preprocess.preprocess(Image.fromarray(clean_render()))
    assert out["steps"] == []


@pytest.mark.skipif(not (omr.COPISTERIA_ROOT / "models" / "evidence-2m.pt").exists(), reason="weights not installed")
def test_omr_clean_page_is_accurate():
    from musicscan.quality import assess
    im = Image.fromarray(clean_render())
    pre = preprocess.preprocess(im)
    r = omr.transcribe(pre["image"], detector="2m")
    assert compare(GT.read_text(), r["xml"])["pitch_f1"] > 0.9
    assert assess(pre, r)["level"] in ("good", "check")
