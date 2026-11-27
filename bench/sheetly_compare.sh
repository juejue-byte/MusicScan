#!/usr/bin/env bash
# Score MusicScan on Sheetly's public OMR benchmark with their own strict-F1 scorer (every page, plus
# "after fixing the marked bars"). Run from the MusicScan folder after scripts/setup.sh:
#   bench/sheetly_compare.sh                 # engrave their ground truth ourselves, photos via their photo_sim.py
#   bench/sheetly_compare.sh path/to/images  # or use their page-image bundle (<suite>/<slug>/p<N>.png)
#   bench/sheetly_compare.sh --max-pages 1   # quick: page one of each piece (about 10 minutes)
#   bench/sheetly_compare.sh --fast          # small detector, no second reading
# The full run reads every page (about 170 pages over both suites), so it takes an hour or more. It resumes if stopped.
set -euo pipefail
cd "$(dirname "$0")/.."
. .venv/bin/activate
[ -d ../omr-benchmark ] || git clone --depth 1 https://github.com/loveranmar/omr-benchmark ../omr-benchmark
python -c 'import cv2, numpy' 2>/dev/null || pip install opencv-python-headless numpy
export MUSICSCAN_DEVICE="${MUSICSCAN_DEVICE:-auto}" PYTORCH_ENABLE_MPS_FALLBACK=1
if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then img="$1"; shift; set -- --images "$img" "$@"; fi
python bench/sheetly_run.py ../omr-benchmark bench/sheetly_out "$@"
echo
echo "Sheetly's published strict F1 (page one only, their images): clean31 97.37%, photo31 97.34%."
echo "Compare with the page-one column above. Other engines on the same page one: Audiveris 88.43% / 50.43%, oemer 38.45% / 9.81%."
