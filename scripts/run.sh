#!/usr/bin/env bash
# Start the MusicScan web app on http://localhost:8000
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d .venv ] && . .venv/bin/activate
python scripts/fetch_models.py >/dev/null || { echo "Model weights missing. Run: scripts/setup.sh" >&2; exit 1; }
# Use the GPU when there is one (Apple Silicon: MPS); unsupported ops fall back to the CPU.
export MUSICSCAN_DEVICE="${MUSICSCAN_DEVICE:-auto}" PYTORCH_ENABLE_MPS_FALLBACK=1
exec uvicorn server.app:app --host "${HOST:-127.0.0.1}" --port "${PORT:-8000}"
