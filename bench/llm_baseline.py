"""Baseline: send the same degraded photos to a general vision LLM (Claude) and ask for MusicXML back, then score it
with the same checks as MusicScan (note F1, plays the same).

  pip install anthropic
  ant auth login            # or export ANTHROPIC_API_KEY=...
  python bench/llm_baseline.py bench/data bench/results [--conds clean,photo] [--only id1,id2] [--model claude-opus-5-5]

Writes bench/results/llm/<id>__<cond>.musicxml and appends rows to bench/results/llm.jsonl. Costs real money:
roughly one image plus a few thousand output tokens per page."""
from __future__ import annotations

import argparse
import base64
import io
import json
import re
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from musicscan.compare import compare, plays_same  # noqa: E402

PROMPT = """This is a photo of one page of printed sheet music. Transcribe every note on it into MusicXML 4.0
(score-partwise). Keep the parts and staves as printed (a piano part is one part with two staves), the clefs, key
and time signatures, every note and rest with its exact pitch and duration, ties, tuplets, chords and voices.
Ignore pen or pencil markings that are not part of the printed music. Reply with the MusicXML only, inside one
```xml code block."""


def ask(client, model: str, img: Path) -> str:
    im = Image.open(img).convert("RGB")
    im.thumbnail((2000, 2000))                       # keep the request within the image size limits
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=90)
    data = base64.standard_b64encode(buf.getvalue()).decode()
    with client.beta.messages.stream(
        model=model,
        max_tokens=64000,
        output_config={"effort": "high"},
        betas=["server-side-fallback-2026-07-01"],
        fallbacks="default",                          # if the request is declined, the API retries on another model
        messages=[{"role": "user", "content": [
            {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": data}},
            {"type": "text", "text": PROMPT},
        ]}],
    ) as stream:
        msg = stream.get_final_message()
    if msg.stop_reason == "refusal":
        raise RuntimeError("declined")
    text = "".join(b.text for b in msg.content if b.type == "text")
    m = re.search(r"```(?:xml)?\s*(.*?)```", text, re.S)
    return (m.group(1) if m else text).strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("data")
    ap.add_argument("out")
    ap.add_argument("--conds", default="clean,photo,combo")
    ap.add_argument("--only", default="")
    ap.add_argument("--model", default="claude-opus-5-5")
    a = ap.parse_args()
    import anthropic
    client = anthropic.Anthropic()
    data, out = Path(a.data), Path(a.out)
    (out / "llm").mkdir(parents=True, exist_ok=True)
    res = out / "llm.jsonl"
    done = {(r["id"], r["cond"]) for r in map(json.loads, res.read_text().splitlines())} if res.exists() else set()
    ids = [m["id"] for m in json.loads((data / "index.json").read_text())]
    for pid in ids:
        if a.only and pid not in a.only.split(","):
            continue
        gt = (data / f"{pid}.musicxml").read_text()
        for cond in a.conds.split(","):
            if (pid, cond) in done:
                continue
            row = {"id": pid, "cond": cond, "model": a.model}
            try:
                xml = ask(client, a.model, out / "images" / f"{pid}__{cond}.jpg")
                (out / "llm" / f"{pid}__{cond}.musicxml").write_text(xml)
                c = compare(gt, xml)
                p = plays_same(gt, xml)
                row.update({k: c[k] for k in ("note_f1", "pitch_f1", "ser", "gt_measures", "pred_measures")})
                row.update({k: p[k] for k in ("play_f1", "identical", "key_ok", "time_ok")})
            except Exception as e:
                row["error"] = f"{type(e).__name__}: {e}"[:300]
            with res.open("a") as f:
                f.write(json.dumps(row) + "\n")
            print(json.dumps(row), flush=True)


if __name__ == "__main__":
    main()
