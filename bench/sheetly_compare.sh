#!/usr/bin/env bash
# Score MusicScan on Sheetly's public OMR benchmark with their own strict-F1 scorer (every page, plus
# "after fixing the marked bars"). Run from the MusicScan folder after scripts/setup.sh:
#   bench/sheetly_compare.sh                 # engrave their ground truth ourselves, photos via their photo_sim.py
#   bench/sheetly_compare.sh path/to/images  # or use their page-image bundle (<suite>/<slug>/p<N>.png)
# Takes about an hour on CPU (49 pages x 2 suites); much less with the Mac GPU.
set -euo pipefail
cd "$(dirname "$0")/.."
. .venv/bin/activate
[ -d ../omr-benchmark ] || git clone --depth 1 https://github.com/loveranmar/omr-benchmark ../omr-benchmark
python -c 'import cv2, numpy' 2>/dev/null || pip install opencv-python-headless numpy
export MUSICSCAN_DEVICE="${MUSICSCAN_DEVICE:-auto}" PYTORCH_ENABLE_MPS_FALLBACK=1
python bench/sheetly_run.py ../omr-benchmark bench/sheetly_out ${1:+--images "$1"}
echo "Their published figures (page one only): python ../omr-benchmark/score.py ../omr-benchmark"
