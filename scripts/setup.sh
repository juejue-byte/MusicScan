#!/usr/bin/env bash
# One-time setup: Python deps, the copisteria OMR reader (pinned) and its weights.
set -euo pipefail
cd "$(dirname "$0")/.."
COPISTERIA_COMMIT=2be4a9d88c15fd6b36fe7c97e0fa816f08804570   # copisteria 1.3.4

# copisteria needs Python 3.12+. Find one: python3.13 / python3.12 on PATH, Homebrew, then uv.
ok_py() { "$1" -c 'import sys; sys.exit(sys.version_info < (3, 12))' 2>/dev/null; }
PY=""
for c in python3.13 python3.12 /opt/homebrew/bin/python3.13 /opt/homebrew/bin/python3.12 \
         /usr/local/bin/python3.13 /usr/local/bin/python3.12 python3; do
  if command -v "$c" >/dev/null 2>&1 && ok_py "$c"; then PY=$(command -v "$c"); break; fi
done
if [ -z "$PY" ] && command -v uv >/dev/null 2>&1; then
  uv python install 3.12 && PY=$(uv python find 3.12)
fi
if [ -z "$PY" ]; then
  echo "MusicScan needs Python 3.12 or newer, and none was found." >&2
  echo "On a Mac:  brew install python@3.12   (or: curl -LsSf https://astral.sh/uv/install.sh | sh)" >&2
  echo "Then run scripts/setup.sh again." >&2
  exit 1
fi
echo "Using $PY ($("$PY" -V))"

# Rebuild .venv if it was made with an older Python.
if [ -d .venv ] && ! ok_py .venv/bin/python; then
  echo "Existing .venv uses $(.venv/bin/python -V 2>&1); rebuilding it with $("$PY" -V)."
  mv .venv ".venv.old.$(date +%s)"
fi
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
python -c 'import copisteria' || { echo "copisteria did not install; see the errors above." >&2; exit 1; }
echo "Done. Start the app with: scripts/run.sh"
