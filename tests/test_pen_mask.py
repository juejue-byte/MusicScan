"""Colored-pen removal must never eat printed ink. Regression: on cream paper in shadow the old HSV mask took the
soft edges of thin barlines and stems for pen and painted them out, so a choir score lost its barlines and the
reader merged bars. Run: python -m pytest tests/test_pen_mask.py -q"""
import sys
from pathlib import Path

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "bench"))

from degrade import camera, lighting  # noqa: E402

from musicscan.preprocess import pen_mask  # noqa: E402


def page(rng):
    """A white page of 4 five-line staves with thin barlines and stems (1-2 px, like a phone photo)."""
    g = np.full((1400, 1000), 255, np.uint8)
    for s in range(4):
        top = 150 + s * 300
        for i in range(5):
            cv2.line(g, (60, top + 18 * i), (940, top + 18 * i), 0, 2)
        for x in range(60, 941, 176):
            cv2.line(g, (x, top), (x, top + 72), 0, 2)                    # barline
        for x in range(100, 900, 44):
            y = top + int(rng.integers(0, 72))
            cv2.ellipse(g, (x, y), (8, 6), -20, 0, 360, 0, -1)
            cv2.line(g, (x + 7, y), (x + 7, y - 55), 0, 1)                 # stem
    return cv2.cvtColor(g, cv2.COLOR_GRAY2RGB)


def test_printed_ink_on_cream_paper_in_shadow_is_not_pen():
    rng = np.random.default_rng(1)
    rgb = page(rng)
    shot = camera(lighting(rgb, rng, shadow=True), rng, blur=1.0, noise=3.0, q=80)
    m = pen_mask(shot)
    ink = cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY) < 128
    assert m[ink].mean() < 0.002, f"{m[ink].mean():.4f} of the printed ink was taken for pen"


def test_colored_pen_still_found():
    rng = np.random.default_rng(2)
    rgb = page(rng)
    marked = rgb.copy()
    cv2.putText(marked, "Slow!", (300, 420), cv2.FONT_HERSHEY_SIMPLEX, 2.0, (200, 30, 40), 5)
    cv2.ellipse(marked, (600, 760), (60, 25), 0, 0, 360, (30, 60, 190), 4)
    cv2.line(marked, (100, 1100), (500, 1130), (20, 140, 60), 5)
    shot = camera(lighting(marked, rng, shadow=True), rng, blur=1.0, noise=3.0, q=80)
    pen = np.any(marked != rgb, axis=2)
    m = pen_mask(shot)
    assert m[pen].mean() > 0.8, f"only {m[pen].mean():.2f} of the pen strokes found"
