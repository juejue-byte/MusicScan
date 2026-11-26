"""Turn a clean render into a realistic phone photo of a marked-up page.

Conditions (each seeded, reproducible):
  clean     the render as is
  photo     page on a desk, perspective tilt, warm light, slight blur, JPEG
  shadow    photo + a hand/phone shadow across the page + vignette
  pen       clean page + red/blue pen markings (circles, arrows, words, fingerings, hairpins)
  pencil    clean page + grey pencil markings (cannot be removed by color)
  combo     photo + shadow + pen
  lowq      a bad photo: far away (low resolution), out of focus, dim, noisy, heavy JPEG -> must be flagged
"""
from __future__ import annotations

import io

import cv2
import numpy as np
from PIL import Image

CONDITIONS = ["clean", "photo", "shadow", "pen", "pencil", "combo", "lowq"]
WORDS = ["Slow!", "cresc.", "breathe", "rit.", "watch!", "p", "mf", "dim.", "Don't rush", "V", "1", "3", "4", "2"]


def _jpeg(rgb: np.ndarray, q: int) -> np.ndarray:
    buf = io.BytesIO()
    Image.fromarray(rgb).save(buf, "JPEG", quality=q)
    return np.asarray(Image.open(buf).convert("RGB"))


def _content_box(gray: np.ndarray):
    ys, xs = np.nonzero(gray < 128)
    return xs.min(), ys.min(), xs.max(), ys.max()


def marks(rgb: np.ndarray, rng, colors, n=14, thick=(3, 5)) -> np.ndarray:
    out = rgb.copy()
    g = cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY)
    x0, y0, x1, y1 = _content_box(g)
    h, w = g.shape
    for i in range(n):
        c = colors[rng.integers(len(colors))]
        t = int(rng.integers(*thick))
        cx, cy = int(rng.uniform(x0, x1)), int(rng.uniform(y0, y1))
        kind = rng.choice(["circle", "word", "arrow", "hairpin", "slur", "word", "tick"])
        if kind == "circle":
            cv2.ellipse(out, (cx, cy), (int(rng.uniform(25, 70)), int(rng.uniform(18, 45))), rng.uniform(-20, 20), 0,
                        rng.uniform(300, 360), c, t, cv2.LINE_AA)
        elif kind == "word":
            cv2.putText(out, str(rng.choice(WORDS)), (cx, cy), cv2.FONT_HERSHEY_SCRIPT_SIMPLEX, rng.uniform(1.0, 1.8),
                        c, t, cv2.LINE_AA)
        elif kind == "arrow":
            cv2.arrowedLine(out, (cx, cy), (cx + int(rng.uniform(-120, 120)), cy + int(rng.uniform(-60, 60))), c, t,
                            cv2.LINE_AA, tipLength=0.25)
        elif kind == "hairpin":
            L = int(rng.uniform(100, 260))
            cv2.line(out, (cx, cy), (cx + L, cy - 14), c, t, cv2.LINE_AA)
            cv2.line(out, (cx, cy), (cx + L, cy + 14), c, t, cv2.LINE_AA)
        elif kind == "slur":
            L = rng.uniform(80, 240)
            pts = np.array([[cx + L * s, cy - 30 * np.sin(np.pi * s)] for s in np.linspace(0, 1, 20)], np.int32)
            cv2.polylines(out, [pts], False, c, t, cv2.LINE_AA)
        else:
            cv2.line(out, (cx, cy), (cx + 12, cy + 16), c, t, cv2.LINE_AA)
            cv2.line(out, (cx + 12, cy + 16), (cx + 34, cy - 20), c, t, cv2.LINE_AA)
    return out


def on_desk(rgb: np.ndarray, rng, tilt=0.07) -> np.ndarray:
    h, w = rgb.shape[:2]
    W, H = int(w * 1.3), int(h * 1.25)
    base = np.array(rng.choice([[120, 85, 55], [70, 80, 95], [150, 140, 125], [40, 90, 80]]), np.float32)
    desk = np.ones((H, W, 3), np.float32) * base
    noise = cv2.GaussianBlur(rng.normal(0, 18, (H, W)).astype(np.float32), (0, 0), 6)
    desk += noise[..., None]
    src = np.float32([[0, 0], [w, 0], [w, h], [0, h]])
    ox, oy = (W - w) / 2, (H - h) / 2
    j = lambda: rng.uniform(-tilt, tilt) * w                                  # noqa: E731
    dst = np.float32([[ox + j(), oy + j()], [ox + w + j(), oy + j()], [ox + w + j(), oy + h + j()], [ox + j(), oy + h + j()]])
    M = cv2.getPerspectiveTransform(src, dst)
    page = cv2.warpPerspective(rgb.astype(np.float32), M, (W, H), flags=cv2.INTER_LINEAR, borderValue=(-1, -1, -1))
    mask = page[..., 0] >= 0
    desk[mask] = page[mask]
    return np.clip(desk, 0, 255).astype(np.uint8)


def lighting(rgb: np.ndarray, rng, shadow=False, warm=True) -> np.ndarray:
    h, w = rgb.shape[:2]
    f = rgb.astype(np.float32)
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    # gradient light + vignette
    ang = rng.uniform(0, 2 * np.pi)
    grad = 0.85 + 0.15 * ((np.cos(ang) * (xx / w - .5) + np.sin(ang) * (yy / h - .5)) + .5)
    vig = 1 - 0.18 * (((xx / w - .5) ** 2 + (yy / h - .5) ** 2) * 2)
    light = grad * vig
    if shadow:
        m = np.zeros((h, w), np.float32)
        cx = rng.uniform(0.2, 0.8) * w
        pts = np.array([[cx, -10], [cx + rng.uniform(0.15, 0.4) * w, -10],
                        [cx + rng.uniform(-0.1, 0.5) * w, h + 10], [cx - rng.uniform(0.1, 0.4) * w, h + 10]], np.int32)
        cv2.fillPoly(m, [pts], 1.0)
        m = cv2.GaussianBlur(m, (0, 0), w * 0.03)
        light *= 1 - rng.uniform(0.35, 0.5) * m
    f *= light[..., None]
    if warm:
        f *= np.array([1.0, 0.93, 0.80], np.float32)
    return np.clip(f, 0, 255).astype(np.uint8)


def camera(rgb: np.ndarray, rng, blur=0.8, noise=3.0, q=88, scale=1.0) -> np.ndarray:
    if scale != 1.0:
        rgb = cv2.resize(rgb, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
    if blur > 0:
        rgb = cv2.GaussianBlur(rgb, (0, 0), blur)
    f = rgb.astype(np.float32) + rng.normal(0, noise, rgb.shape)
    return _jpeg(np.clip(f, 0, 255).astype(np.uint8), q)


RED, BLUE, GREEN = (200, 30, 40), (30, 60, 190), (20, 140, 60)


def degrade(rgb: np.ndarray, cond: str, seed: int = 0) -> np.ndarray:
    rng = np.random.default_rng(seed)
    if cond == "clean":
        return rgb
    if cond == "pen":
        return marks(rgb, rng, [RED, BLUE, GREEN])
    if cond == "pencil":
        return camera(marks(rgb, rng, [(95, 95, 95), (80, 80, 85)], thick=(2, 4)), rng, blur=0.6, noise=2)
    if cond == "photo":
        return camera(lighting(on_desk(rgb, rng), rng), rng)
    if cond == "shadow":
        return camera(lighting(on_desk(rgb, rng), rng, shadow=True), rng)
    if cond == "combo":
        return camera(lighting(on_desk(marks(rgb, rng, [RED, BLUE]), rng), rng, shadow=True), rng)
    if cond == "lowq":
        im = lighting(on_desk(rgb, rng, tilt=0.1), rng, shadow=True)
        im = (im.astype(np.float32) * 0.55).astype(np.uint8)
        return camera(im, rng, blur=2.2, noise=9, q=25, scale=0.42)
    raise ValueError(cond)
