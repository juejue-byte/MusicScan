"""Download the copisteria weights (Apache-2.0) into third_party/copisteria/models and check they are all there.

  python scripts/fetch_models.py            # safe to re-run; skips files that are already complete
Exit code 1, with a clear message, if any file is still missing."""
from __future__ import annotations

import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODELS = Path(os.environ.get("COPISTERIA_ROOT", ROOT / "third_party" / "copisteria")) / "models"

# (Hugging Face repo, file in that repo, minimum size in bytes)
NEEDED = [
    ("kobimusic/copista-28m", "evidence-2m.pt", 5_000_000),
    ("kobimusic/copista-28m", "small/v7_obj-recall-30m_best.pt", 100_000_000),
    ("kobimusic/copista-2m", "small/v7_obj-recall_best.pt", 5_000_000),
]


def ok(rel: str, size: int) -> bool:
    p = MODELS / rel
    return p.is_file() and p.stat().st_size >= size


def main() -> int:
    if not MODELS.parent.is_dir():
        print(f"copisteria is not at {MODELS.parent}. Run scripts/setup.sh first.", file=sys.stderr)
        return 1
    MODELS.mkdir(parents=True, exist_ok=True)
    from huggingface_hub import hf_hub_download
    for repo, rel, size in NEEDED:
        if ok(rel, size):
            print(f"  ok  {rel}")
            continue
        print(f"  get {rel}  (from {repo})")
        for attempt in range(3):
            try:
                hf_hub_download(repo, rel, local_dir=str(MODELS))
                break
            except Exception as e:  # network hiccup: retry, then report
                if attempt == 2:
                    print(f"      failed: {e}", file=sys.stderr)
    missing = [rel for _, rel, size in NEEDED if not ok(rel, size)]
    if missing:
        print("\nStill missing: " + ", ".join(missing) + f"\nin {MODELS}\n"
              "Check your internet connection and run  python scripts/fetch_models.py  again.", file=sys.stderr)
        return 1
    print(f"All weights present in {MODELS}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
