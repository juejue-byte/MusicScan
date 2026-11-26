"""omr.page_inputs (the big detector reads the page once instead of twice) must give exactly what copisteria's pipeline.inputs gives.
Run: python -m pytest tests/test_fast_inputs.py -q   (skipped without the weights; about a minute on a CPU)."""
import os
import sys
import tempfile
from pathlib import Path

import numpy as np
import pytest
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from musicscan import omr  # noqa: E402

SAMPLE = Path(__file__).resolve().parents[1] / "web" / "samples" / "1_Piano_scan.jpg"


@pytest.mark.skipif(not (omr.COPISTERIA_ROOT / "models" / "evidence-2m.pt").exists(), reason="weights not installed")
@pytest.mark.parametrize("detector", ["28m", "2m"])
def test_page_inputs_match_pipeline(detector):
    model = omr._setup()
    from copisteria import pipeline
    os.environ["COPISTERIA_DETECTOR"] = detector
    pipeline._DET[:] = []
    with tempfile.TemporaryDirectory() as td:
        a = Path(td) / "a" / "page.png"
        b = Path(td) / "b" / "page.png"
        for p in (a, b):
            p.parent.mkdir()
            Image.open(SAMPLE).convert("L").save(p)
        d1, c1, f1 = pipeline.inputs(a, model)
        d2, c2, f2 = omr.page_inputs(b, model)
    assert d1 == d2
    assert c1 == c2
    assert (f1 is None and f2 is None) or np.array_equal(f1, f2)
