#!/usr/bin/env bash
# One-time setup: Python deps, the copisteria OMR reader (pinned) and its weights.
set -euo pipefail
cd "$(dirname "$0")/.."
COPISTERIA_COMMIT=2be4a9d88c15fd6b36fe7c97e0fa816f08804570   # copisteria 1.3.4

PY=python3
for v in python3.13 python3.12; do command -v "$v" >/dev/null && { PY=$v; break; }; done
"$PY" -c 'import sys; assert sys.version_info >= (3, 12), "Python 3.12+ is needed (brew install python@3.12)"'
[ -d .venv ] || "$PY" -m venv .venv
. .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

mkdir -p third_party
if [ ! -d third_party/copisteria/.git ]; then
  git clone https://github.com/kobimusic/copisteria third_party/copisteria
fi
git -C third_party/copisteria fetch --depth 1 origin "$COPISTERIA_COMMIT" || true
git -C third_party/copisteria checkout -q "$COPISTERIA_COMMIT"
pip install --no-deps -e third_party/copisteria

# weights (Apache-2.0): evidence model, copista-28m (default) and copista-2m (fast mode / rescan).
# Uses the Python API, so it works with any huggingface_hub version, and fails loudly if a file is missing.
python scripts/fetch_models.py
echo "Done. Start the app with: scripts/run.sh"
