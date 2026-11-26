"""Precompute the sample photos through the real pipeline for the static preview (web/demo/, read by web/js/demo.js).

    .venv/bin/python scripts/build_demo.py            # all samples, 3 rescan ways per row
    .venv/bin/python scripts/build_demo.py --ways 1   # quicker
"""
from __future__ import annotations

import argparse
import json
import shutil
import sys
import time
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from fastapi.testclient import TestClient  # noqa: E402

from server.app import WORK, app  # noqa: E402

OUT = ROOT / "web" / "demo"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ways", type=int, default=3)
    args = ap.parse_args()
    c = TestClient(app)
    names = c.get("/api/samples").json()
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True)
    index = {"built": time.strftime("%Y-%m-%d"), "samples": {}}
    for k, name in enumerate(names, 1):
        slug = f"sample{k}"
        data = (ROOT / "web" / "samples" / name).read_bytes()
        jid = c.post("/api/jobs", files={"file": (name, data, "image/jpeg")}, data={"detector": "28m"}).json()["id"]
        while (j := c.get(f"/api/jobs/{jid}").json())["status"] not in ("done", "error"):
            time.sleep(0.5)
        if j["status"] == "error":
            raise SystemExit(f"{name}: {j['error']}")
        d = OUT / slug
        d.mkdir()
        j["id"] = slug
        (d / "job.json").write_text(json.dumps(j))
        Image.open(WORK / jid / "page.png").convert("L").save(d / "page.jpg", quality=82)
        shutil.copy(WORK / jid / "original.jpg", d / "original.jpg")
        meas = j["result"]["measures"]
        systems = sorted({m["system"] for m in meas})
        for s in systems:
            first = next(m["index"] for m in meas if m["system"] == s)
            for a in range(args.ways):
                r = c.post(f"/api/jobs/{jid}/rescan", data={"measures": str(first), "attempt": str(a)})
                if r.status_code == 200:
                    (d / f"rescan_{s}_{a}.json").write_text(r.text)
        index["samples"][name] = slug
        print(f"{name}: {len(meas)} bars, {len(systems)} rows, {j['result']['seconds']}s", flush=True)
    (OUT / "index.json").write_text(json.dumps(index, indent=1))


if __name__ == "__main__":
    main()
