#!/usr/bin/env bash
# One-time setup: Python deps, the copisteria OMR reader (pinned) and its weights.
set -euo pipefail
cd "$(dirname "$0")/.."
COPISTERIA_COMMIT=2be4a9d88c15fd6b36fe7c97e0fa816f08804570   # copisteria 1.3.4

python3 -m venv .venv
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

# weights (Apache-2.0): copista-28m (default) and copista-2m (fast mode / rescan)
hf download kobimusic/copista-28m --include "*.pt" --local-dir third_party/copisteria/models
hf download kobimusic/copista-2m --include "*.pt" --local-dir third_party/copisteria/models
echo "Done. Start the app with: scripts/run.sh"
