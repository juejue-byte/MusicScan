"""Photo cleanup before OMR: page lock (perspective flatten), colored-pen removal, shadow flattening,
and image-quality measurements used by the low-quality warning."""
from __future__ import annotations

import cv2
import numpy as np
from PIL import Image


def _order(pts: np.ndarray) -> np.ndarray:
    pts = pts.reshape(4, 2).astype(np.float32)
    s, d = pts.sum(1), np.diff(pts, axis=1).ravel()
    return np.array([pts[s.argmin()], pts[d.argmin()], pts[s.argmax()], pts[d.argmax()]], np.float32)  # tl tr br bl


def order_quad(pts) -> list:
    """Four corners in any order -> [tl, tr, br, bl] as plain lists (for corners placed by hand)."""
    return _order(np.asarray(pts, np.float32)).tolist()


def _hugs_frame(q: np.ndarray, shape, tol: float = 0.01) -> bool:
    """True when a page outline runs along the photo's own edge: a corner sits on a corner of the frame, or two
    neighbouring corners sit on the same side of it. On a wood table the bright grain merges with the page and the
    biggest outline grabs the frame; warping to it keeps a strip of desk, tilts the page, and on single-staff music
    bends rows so far that the reader splits a row into a second, made-up part. A real page can touch one side of
    the photo, but its outline does not follow the frame."""
    h, w = shape[:2]
    t = tol * max(h, w)
    sides = [{s for s, on in (("l", x <= t), ("r", x >= w - 1 - t), ("t", y <= t), ("b", y >= h - 1 - t)) if on}
             for x, y in q]
    if any(len(s) == 2 for s in sides):
        return True
    return any(sides[i] & sides[(i + 1) % 4] for i in range(4))


def _paper_mask(small: np.ndarray) -> np.ndarray:
    """Bright, nearly colourless pixels: paper. A wood table, a carpet or a hand is darker or clearly coloured,
    even where it is as bright as the page (pale wood grain), which Otsu on brightness alone can't tell apart. A
    shadow darkens paper but leaves it colourless, so the brightness bar is low."""
    hsv = cv2.cvtColor(small, cv2.COLOR_RGB2HSV)
    s, v = hsv[..., 1].astype(np.float32), hsv[..., 2].astype(np.float32)
    lit = v >= np.percentile(v, 95) * 0.35          # loose, so a shadowed part of the page still counts
    m = ((s < 40) & lit).astype(np.uint8) * 255
    m = cv2.morphologyEx(m, cv2.MORPH_CLOSE, np.ones((25, 25), np.uint8))   # print and staff lines inside the page
    return cv2.morphologyEx(m, cv2.MORPH_OPEN, np.ones((9, 9), np.uint8))


def find_page(rgb: np.ndarray) -> np.ndarray | None:
    """The page's four corners (tl, tr, br, bl) in image pixels, or None when the page already fills the frame
    or no clear quadrilateral is found. Outlines come from brightness (Otsu), edges and paper colour (bright and
    colourless, which pale wood grain is not); outlines that follow the photo's own frame are dropped."""
    h, w = rgb.shape[:2]
    k = 900 / max(h, w)
    small = cv2.resize(rgb, (round(w * k), round(h * k)), interpolation=cv2.INTER_AREA)
    gray = cv2.cvtColor(small, cv2.COLOR_RGB2GRAY)
    gray = cv2.GaussianBlur(gray, (7, 7), 0)
    area = gray.shape[0] * gray.shape[1]
    cands = []
    _, th = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    th = cv2.morphologyEx(th, cv2.MORPH_CLOSE, np.ones((25, 25), np.uint8))
    edges = cv2.dilate(cv2.Canny(gray, 40, 120), np.ones((5, 5), np.uint8))
    for mask in (th, edges, _paper_mask(small)):
        cs, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        for c in sorted(cs, key=cv2.contourArea, reverse=True)[:3]:
            a = cv2.contourArea(c)
            if a < 0.25 * area:
                continue
            hull = cv2.convexHull(c)
            peri = cv2.arcLength(hull, True)
            for eps in (0.02, 0.03, 0.05):
                ap = cv2.approxPolyDP(hull, eps * peri, True)
                if len(ap) == 4:
                    if not _hugs_frame(_order(ap), gray.shape):
                        cands.append((cv2.contourArea(ap), ap))
                    break
    if not cands:
        return None
    a, quad = max(cands, key=lambda t: t[0])
    if a > 0.93 * area:
        return None  # page fills the frame: a scan, nothing to flatten
    return _order(quad) / k


def warp_page(rgb: np.ndarray, quad: np.ndarray) -> np.ndarray:
    tl, tr, br, bl = quad
    wd = int(max(np.linalg.norm(tr - tl), np.linalg.norm(br - bl)))
    ht = int(max(np.linalg.norm(bl - tl), np.linalg.norm(br - tr)))
    dst = np.array([[0, 0], [wd - 1, 0], [wd - 1, ht - 1], [0, ht - 1]], np.float32)
    M = cv2.getPerspectiveTransform(quad.astype(np.float32), dst)
    return cv2.warpPerspective(rgb, M, (wd, ht), flags=cv2.INTER_CUBIC, borderValue=(255, 255, 255))


def pen_mask(rgb: np.ndarray) -> np.ndarray:
    """Pixels of colored ink (red/blue/green pen, highlighter).

    Works in Lab color: printed ink is black, so every ink pixel - including the soft edges of thin barlines and
    stems - is a mix of black and paper, and its color (a*, b*) lies on the line from neutral to the paper's own
    tint. On cream or yellowed paper those edges look "saturated" in HSV, which used to erase barlines. Pen and
    highlighter sit off that line (a different hue) or far beyond it (much stronger than the paper's tint)."""
    lab = cv2.cvtColor(rgb, cv2.COLOR_RGB2LAB).astype(np.float32)
    L, ab = lab[..., 0] * (100 / 255), lab[..., 1:] - 128
    bright = L >= np.percentile(L, 60)
    paper = np.median(ab[bright], axis=0) if bright.any() else np.zeros(2, np.float32)
    n = float(np.hypot(*paper))
    if n > 1:
        u = paper / n
        along = ab @ u                                   # how much of the paper's tint
        perp = np.abs(ab @ np.array([-u[1], u[0]], np.float32))
    else:
        along = np.zeros(L.shape, np.float32)
        perp = np.hypot(ab[..., 0], ab[..., 1])
    m = ((perp > 9) | (along > n + 30)) & (L > 6)
    m = cv2.morphologyEx(m.astype(np.uint8), cv2.MORPH_OPEN, np.ones((2, 2), np.uint8))   # lone noisy pixels
    m = cv2.dilate(m, np.ones((3, 3), np.uint8)) > 0
    return m


def background(gray: np.ndarray) -> np.ndarray:
    h, w = gray.shape
    k = 400 / max(h, w)
    small = cv2.resize(gray, (max(8, round(w * k)), max(8, round(h * k))), interpolation=cv2.INTER_AREA)
    bg = cv2.morphologyEx(small, cv2.MORPH_CLOSE, np.ones((9, 9), np.uint8))   # remove the ink
    bg = cv2.medianBlur(bg, 21)
    return cv2.resize(bg, (w, h), interpolation=cv2.INTER_CUBIC).astype(np.float32)


def flatten_light(gray: np.ndarray, bg: np.ndarray | None = None) -> np.ndarray:
    bg = background(gray) if bg is None else bg
    norm = gray.astype(np.float32) / np.maximum(bg, 1) * 255
    lo = np.percentile(norm, 1)
    norm = (norm - lo) / max(1, 250 - lo) * 255
    return np.clip(norm, 0, 255).astype(np.uint8)


def measure(gray: np.ndarray) -> dict:
    """Image-quality numbers on a page-sized grey image."""
    h, w = gray.shape
    k = 1600 / max(h, w)
    g = cv2.resize(gray, (round(w * k), round(h * k)), interpolation=cv2.INTER_AREA) if k < 1 else gray
    bg = background(g)
    ink = g < (bg * 0.6)
    ink_frac = float(ink.mean())
    # sharpness: strength of the steepest edges (p99 of the gradient), relative to the ink/paper contrast
    gx = cv2.Sobel(g, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(g, cv2.CV_32F, 0, 1, ksize=3)
    mag = np.hypot(gx, gy)
    paper = float(np.median(bg))
    inkv = float(np.percentile(g[ink], 30)) if ink.any() else paper
    contrast = paper - inkv
    sharp = float(np.percentile(mag, 99.5)) / max(contrast, 1) / 4
    return {
        "width": int(w), "height": int(h),
        "paper": round(paper, 1), "contrast": round(contrast, 1),
        "uneven": round(float(np.std(bg) / max(np.mean(bg), 1)), 3),
        "dark": round(float(np.percentile(bg, 5)), 1),
        "sharpness": round(sharp, 3), "ink": round(ink_frac, 4),
    }


def preprocess(im: Image.Image, flatten: bool | None = None, strip_pen: bool = True, lock_page: bool = True,
               quad: list | None = None) -> dict:
    """Returns {"image": PIL grey page, "quad", "steps": [...], "metrics": {...}, "pen_frac"}."""
    rgb = np.asarray(im.convert("RGB"))
    steps = []
    q = np.array(quad, np.float32) if quad is not None else (find_page(rgb) if lock_page else None)
    if q is not None:
        rgb = warp_page(rgb, q)
        steps.append("page-flatten")
    pen_frac = 0.0
    if strip_pen:
        m = pen_mask(rgb)
        pen_frac = float(m.mean())
        if pen_frac > 0.0005:
            rgb = rgb.copy()
            gray0 = cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY)
            paper = np.percentile(gray0, 90)
            rgb[m] = paper
            steps.append("pen-removed")
    gray = cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY)
    before = measure(gray)
    if flatten is None:
        flatten = before["uneven"] > 0.06 or before["paper"] < 175 or before["contrast"] < 90
    if flatten:
        gray = flatten_light(gray)
        steps.append("shadow-flatten")
    return {"image": Image.fromarray(gray), "quad": None if q is None else q.tolist(), "steps": steps,
            "metrics": before, "pen_frac": round(pen_frac, 4)}
