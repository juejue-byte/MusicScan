#!/usr/bin/env bash
# Start the MusicScan web app on http://localhost:8000
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d .venv ] && . .venv/bin/activate
exec uvicorn server.app:app --host "${HOST:-127.0.0.1}" --port "${PORT:-8000}"
