"""Decode uploads (JPG/PNG/WEBP/HEIC/PDF) into an RGB PIL image with EXIF orientation applied."""
from __future__ import annotations

import io

from PIL import Image, ImageOps

try:  # decode-only HEIC support (LGPL libheif; no GPL encoder, unlike pillow-heif wheels)
    import pi_heif
    pi_heif.register_heif_opener()
    HEIC = True
except Exception:  # pragma: no cover
    HEIC = False

MAX_SIDE = 3600


def load_image(data: bytes, filename: str = "", page: int = 0) -> Image.Image:
    name = filename.lower()
    if name.endswith(".pdf") or data[:5] == b"%PDF-":
        import pypdfium2 as pdfium
        pdf = pdfium.PdfDocument(data)
        p = pdf[min(page, len(pdf) - 1)]
        w, h = p.get_size()
        scale = min(300 / 72, MAX_SIDE / max(w, h))
        im = p.render(scale=scale).to_pil().convert("RGB")
        return im
    im = Image.open(io.BytesIO(data))
    im = ImageOps.exif_transpose(im)
    if im.mode in ("RGBA", "LA", "P"):
        bg = Image.new("RGB", im.size, "white")
        im = im.convert("RGBA")
        bg.paste(im, mask=im.split()[-1])
        im = bg
    im = im.convert("RGB")
    if max(im.size) > MAX_SIDE:
        s = MAX_SIDE / max(im.size)
        im = im.resize((round(im.width * s), round(im.height * s)), Image.LANCZOS)
    return im
