"""MusicScan reading server on Modal (https://modal.com): split CPU web/API + snapshot-accelerated GPU OMR worker.

  pip install modal && modal setup                         # once: log in to your Modal account
  modal secret create musicscan MUSICSCAN_ACCESS_KEY=<key>  # once: the key that keeps strangers off your GPU
  modal deploy deploy/modal_app.py                          # prints  https://<you>--musicscan.modal.run

Architecture (cost & cold-start optimized):
  - `web`: cheap CPU-only ASGI container (1 vCPU, 1 GiB RAM, no PyTorch) serving static assets, auth, StoreKit
    billing, job polling, and instant $0-GPU cached sample scans.
  - `OMRWorker`: dedicated GPU container with Modal Memory Snapshots (`enable_memory_snapshot=True`) and a short
    `scaledown_window=75`s, invoked over RPC only when an uncached page or rescan actually needs GPU OMR.
"""
from __future__ import annotations

import io
import os
from pathlib import Path

import modal

ROOT = Path(__file__).resolve().parents[1]
COPISTERIA_COMMIT = "2be4a9d88c15fd6b36fe7c97e0fa816f08804570"  # copisteria 1.3.4, same pin as scripts/setup.sh
GPU = os.environ.get("MUSICSCAN_GPU", "T4")  # T4 is the cheapest; "L4" is ~1.4x the price and a bit faster
GPU_SCALEDOWN = int(os.environ.get("MUSICSCAN_GPU_SCALEDOWN", "180"))
IGNORE = ["**/__pycache__", "**/*.pyc", "**/.DS_Store"]

# Lightweight CPU image for static files, preprocessing, auth, billing, and job orchestration.
# Keeps PyTorch and model weights completely off the web tier for fast cold starts and ~80% lower idle cost.
web_image = (
    modal.Image.debian_slim(python_version="3.12")
    .pip_install(
        "fastapi>=0.115",
        "uvicorn>=0.30",
        "python-multipart>=0.0.9",
        "numpy>=1.26",
        "scipy>=1.11",
        "opencv-python-headless>=4.10",
        "Pillow>=10.0",
        "pi-heif>=0.18",
        "pypdfium2>=4.30",
        "lxml>=5.0",
        "pyjwt[crypto]>=2.8",
        "app-store-server-library==3.1.2",
    )
    .env({
        "MUSICSCAN_WORK": "/work",
        "MUSICSCAN_DEVICE": "cpu",
    })
    .add_local_dir(ROOT / "musicscan", "/app/musicscan", ignore=IGNORE)
    .add_local_dir(ROOT / "server", "/app/server", ignore=IGNORE)
    .add_local_dir(ROOT / "web", "/app/web", ignore=IGNORE)
)

# Dedicated GPU image with PyTorch, copisteria, and baked Apache-2.0 weights.
gpu_image = (
    modal.Image.debian_slim(python_version="3.12")
    .apt_install("git")
    .pip_install(
        "numpy>=1.26",
        "scipy>=1.11",
        "Pillow>=10.0",
        "lxml>=5.0",
        "torch>=2.3",
        "torchvision>=0.18",
        "huggingface_hub>=0.24",
    )
    .run_commands(
        "git clone https://github.com/kobimusic/copisteria /opt/copisteria",
        f"git -C /opt/copisteria checkout -q {COPISTERIA_COMMIT}",
        "pip install --no-deps -e /opt/copisteria",
    )
    .env({
        "COPISTERIA_ROOT": "/opt/copisteria",
        "MUSICSCAN_DEVICE": "auto",
        "HF_HUB_DISABLE_TELEMETRY": "1",
    })
    # Weights (Apache-2.0) are baked into the image, so a cold start does not download them.
    .add_local_file(ROOT / "scripts" / "fetch_models.py", "/app/scripts/fetch_models.py", copy=True)
    .run_commands("python /app/scripts/fetch_models.py")
    .add_local_dir(ROOT / "musicscan", "/app/musicscan", ignore=IGNORE)
)

app = modal.App("musicscan")
work = modal.Volume.from_name("musicscan-work", create_if_missing=True)


@app.cls(
    gpu=GPU,
    cpu=4.0,                    # the copisteria reviser runs on CPU alongside GPU detection
    memory=8192,
    image=gpu_image,
    enable_memory_snapshot=True,
    scaledown_window=GPU_SCALEDOWN,  # release GPU quickly after scanning finishes (default 75s vs 600s)
    timeout=300,
)
class OMRWorker:
    @modal.enter(snap=True)
    def load_cpu_snapshot(self):
        """Snapshot Python, PyTorch, copisteria, and the CPU evidence model into RAM before GPU attachment."""
        import sys
        sys.path.insert(0, "/app")
        from musicscan import omr
        omr._setup()
        print("OMRWorker CPU snapshot ready (evidence model preloaded)")

    @modal.enter(snap=False)
    def attach_gpu(self):
        """After restoring from the memory snapshot, bind CUDA, preload 28m + 2m detectors, and warm CUDA kernels."""
        import sys
        sys.path.insert(0, "/app")
        from PIL import Image
        from musicscan import omr
        omr._DEV.clear()
        dev = omr.pick_device()
        try:
            from copisteria.detect import Detector
            from copisteria.paths import DETECTORS
            dummy = Image.new("L", (128, 128), 255)
            for name in ("28m", "2m"):
                os.environ["COPISTERIA_DETECTOR"] = name
                det = Detector(DETECTORS[name][0])
                arr, sc = det.prepare(dummy, 256)
                det.run_array(arr, sc)
            os.environ["COPISTERIA_DETECTOR"] = "28m"
        except Exception as exc:
            print(f"OMRWorker detector warmup skipped: {exc}")
        print(f"OMRWorker GPU ready on {dev} (28m + 2m hot)")

    @modal.method()
    def warmup(self) -> dict:
        """No-op ping used to wake & restore the GPU container before the user finishes capturing a page."""
        from musicscan import omr
        return {"ok": True, "device": omr.pick_device()}

    @modal.method()
    def transcribe_page(self, png_bytes: bytes, detector: str = "28m", allow_second_opinion: bool = True) -> dict:
        from PIL import Image
        from musicscan import omr

        img = Image.open(io.BytesIO(png_bytes))
        r, read_im = omr.transcribe_checked(img, detector=detector)
        if allow_second_opinion and detector == "28m":
            if omr.should_skip_second_opinion(r):
                r["second_opinion"] = {
                    "aligned": True,
                    "skipped": True,
                    "reason": "no_measures" if not (r.get("stats") or {}).get("measures") else "high_confidence",
                    "bars": 0,
                    "filled": [],
                    "seconds": 0.0,
                }
            else:
                omr.second_opinion(r, read_im)
        return r

    @modal.method()
    def rescan_crop(self, png_bytes: bytes, detector: str = "28m") -> dict:
        from PIL import Image
        from musicscan import omr

        img = Image.open(io.BytesIO(png_bytes))
        return omr.transcribe(img, detector=detector)


@app.function(
    cpu=1.0,
    memory=1024,
    image=web_image,
    volumes={"/work": work},
    secrets=[modal.Secret.from_name("musicscan")],
    max_containers=1,           # JOBS dict stays in-process across upload, poll, and rescan
    scaledown_window=300,       # cheap CPU tier stays warm 5 min; GPU sleeps independently after 75s
    timeout=900,
)
@modal.concurrent(max_inputs=64)
@modal.asgi_app(label="musicscan")
def web():
    import sys
    sys.path.insert(0, "/app")
    from server import app as srv

    worker = OMRWorker()

    def _encode_png(img) -> bytes:
        buf = io.BytesIO()
        img.convert("L").save(buf, format="PNG", compress_level=1)
        return buf.getvalue()

    def remote_transcribe(img, detector: str = "28m", allow_second_opinion: bool = True) -> dict:
        return worker.transcribe_page.remote(
            _encode_png(img),
            detector=detector,
            allow_second_opinion=allow_second_opinion,
        )

    import threading
    import time

    warm_lock = threading.Lock()
    last_warm = [0.0]

    def remote_rescan(img, detector: str = "28m") -> dict:
        return worker.rescan_crop.remote(_encode_png(img), detector=detector)

    def remote_warmup() -> bool:
        now = time.monotonic()
        with warm_lock:
            if now - last_warm[0] < 20.0:
                return False
            last_warm[0] = now
        try:
            worker.warmup.spawn()
            return True
        except Exception as exc:
            print(f"OMRWorker warmup spawn failed: {exc}")
            return False

    srv.set_omr_backend(
        remote_transcribe,
        remote_rescan,
        device_label=f"modal-{GPU.lower()}",
        warmup_fn=remote_warmup,
    )
    print(f"MusicScan CPU web ready (delegating OMR to {GPU} OMRWorker, scaledown={GPU_SCALEDOWN}s)")
    return srv.app
