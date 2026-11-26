"""MusicScan reading server on Modal (https://modal.com): a public HTTPS address with a GPU, for testing the
iPhone / iPad app end to end.

  pip install modal && modal setup                         # once: log in to your Modal account
  modal secret create musicscan MUSICSCAN_ACCESS_KEY=<key>  # once: the key that keeps strangers off your GPU
  modal deploy deploy/modal_app.py                          # prints  https://<you>--musicscan.modal.run

Full steps, costs and how the app finds the server: deploy/README.md.

One container serves everything (max_containers=1): jobs are kept in memory between the upload, the polling and
the rescans, so they must all reach the same process. That is plenty for testing and a small beta; before launch,
jobs move to shared storage so more containers can run (see deploy/README.md, "Before launch").
"""
from __future__ import annotations

import os
from pathlib import Path

import modal

ROOT = Path(__file__).resolve().parents[1]
COPISTERIA_COMMIT = "2be4a9d88c15fd6b36fe7c97e0fa816f08804570"  # copisteria 1.3.4, same pin as scripts/setup.sh
GPU = os.environ.get("MUSICSCAN_GPU", "T4")  # T4 is the cheapest; "L4" is ~1.4x the price and a bit faster
IGNORE = ["**/__pycache__", "**/*.pyc", "**/.DS_Store"]

image = (
    modal.Image.debian_slim(python_version="3.12")
    .apt_install("git")
    # The server's half of requirements.txt (the benchmark tools are not needed here).
    .pip_install(
        "fastapi>=0.115", "uvicorn>=0.30", "python-multipart>=0.0.9", "numpy>=1.26", "scipy>=1.11",
        "opencv-python-headless>=4.10", "Pillow>=10.0", "pi-heif>=0.18", "pypdfium2>=4.30", "lxml>=5.0",
        "torch>=2.3", "torchvision>=0.18", "huggingface_hub>=0.24", "pyjwt[crypto]>=2.8",
        "app-store-server-library==3.1.2",
    )
    .run_commands(
        "git clone https://github.com/kobimusic/copisteria /opt/copisteria",
        f"git -C /opt/copisteria checkout -q {COPISTERIA_COMMIT}",
        "pip install --no-deps -e /opt/copisteria",
    )
    .env({"COPISTERIA_ROOT": "/opt/copisteria", "MUSICSCAN_WORK": "/work", "MUSICSCAN_DEVICE": "auto",
          "HF_HUB_DISABLE_TELEMETRY": "1"})
    # Weights (Apache-2.0) are baked into the image, so a cold start does not download them.
    .add_local_file(ROOT / "scripts" / "fetch_models.py", "/app/scripts/fetch_models.py", copy=True)
    .run_commands("python /app/scripts/fetch_models.py")
    # The app itself last, so code changes redeploy in seconds without rebuilding the layers above.
    .add_local_dir(ROOT / "musicscan", "/app/musicscan", ignore=IGNORE)
    .add_local_dir(ROOT / "server", "/app/server", ignore=IGNORE)
    .add_local_dir(ROOT / "web", "/app/web", ignore=IGNORE)
)

app = modal.App("musicscan", image=image)
work = modal.Volume.from_name("musicscan-work", create_if_missing=True)


@app.function(
    gpu=GPU,
    cpu=4.0,              # the reviser and photo clean-up run on the CPU
    memory=8192,
    volumes={"/work": work},
    secrets=[modal.Secret.from_name("musicscan")],
    max_containers=1,     # see the note at the top
    scaledown_window=600,  # stay warm 10 minutes after the last request, then scale to zero (no cost while idle)
    timeout=900,
)
@modal.concurrent(max_inputs=32)  # polling, page images and the editor's files share the one container
@modal.asgi_app(label="musicscan")
def web():
    import sys
    sys.path.insert(0, "/app")
    from musicscan import omr
    from server.app import app as fastapi_app
    omr._setup()  # load the evidence model now rather than on the first photo
    print(f"MusicScan ready on {omr.pick_device()}")
    return fastapi_app
