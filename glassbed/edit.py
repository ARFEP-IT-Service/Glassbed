"""Non-destructive page edits: rotate, straighten, crop, brightness, contrast, redact.

The original scan is kept; an ``Edits`` record describes what to do with it, so a
page can be re-edited or reset at any time.

Redactions are stored as polygons in the *original* page's coordinates and painted onto
the original before anything else happens, so they stay on the content when the page is
rotated or straightened, and the covered pixels never reach the saved file.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, replace

import numpy as np
from PIL import Image, ImageDraw, ImageEnhance, ImageFilter

FULL = (0.0, 0.0, 1.0, 1.0)

Point = tuple[float, float]
# (polygon in original-page coordinates 0..1, "black" | "white" | "blur")
Redaction = tuple[tuple[Point, ...], str]


@dataclass(frozen=True)
class Edits:
    rotate: int = 0                     # quarter turns, degrees counter-clockwise (0/90/180/270)
    angle: float = 0.0                  # fine straightening, degrees counter-clockwise
    crop: tuple[float, float, float, float] = FULL   # left, top, right, bottom (0..1)
    brightness: float = 1.0
    contrast: float = 1.0
    redactions: tuple[Redaction, ...] = ()

    @property
    def is_identity(self) -> bool:
        return self == Edits()

    def rotated(self, degrees: int) -> "Edits":
        """Quarter-turn the page; the crop rectangle turns with it (redactions already do)."""
        return replace(self, rotate=(self.rotate + degrees) % 360,
                       crop=rotate_crop(self.crop, degrees))


# -- coordinates: original page  <->  rotated/straightened frame (what the editor shows) ----
def _quarter_size(size: tuple[int, int], rotate: int) -> tuple[int, int]:
    w, h = size
    return (h, w) if (rotate // 90) % 2 else (w, h)


def to_frame(pts, size: tuple[int, int], e: Edits) -> list[Point]:
    """Map normalised points of the original page into the edited frame."""
    out = []
    W, H = _quarter_size(size, e.rotate)
    a = math.radians(e.angle)
    for x, y in pts:
        for _ in range((e.rotate // 90) % 4):          # one counter-clockwise quarter turn
            x, y = y, 1 - x
        if abs(e.angle) > 0.01:
            dx, dy = (x - 0.5) * W, (y - 0.5) * H
            x = 0.5 + (dx * math.cos(a) + dy * math.sin(a)) / W
            y = 0.5 + (-dx * math.sin(a) + dy * math.cos(a)) / H
        out.append((x, y))
    return out


def from_frame(pts, size: tuple[int, int], e: Edits) -> list[Point]:
    """Inverse of :func:`to_frame` – used when the user draws on the edited view."""
    out = []
    W, H = _quarter_size(size, e.rotate)
    a = math.radians(e.angle)
    for x, y in pts:
        if abs(e.angle) > 0.01:
            dx, dy = (x - 0.5) * W, (y - 0.5) * H
            x = 0.5 + (dx * math.cos(a) - dy * math.sin(a)) / W
            y = 0.5 + (dx * math.sin(a) + dy * math.cos(a)) / H
        for _ in range((e.rotate // 90) % 4):          # undo the quarter turns
            x, y = 1 - y, x
        out.append((x, y))
    return out


def _fill(img: Image.Image, color: str):
    if img.mode == "1":
        return 0 if color == "black" else 255
    if img.mode == "L":
        return 0 if color == "black" else 255
    return (0, 0, 0) if color == "black" else (255, 255, 255)


def paint_redactions(img: Image.Image, redactions, transform=None) -> Image.Image:
    """Paint redaction polygons (normalised) onto a copy of ``img``."""
    if not redactions:
        return img
    img = img.copy()
    draw = ImageDraw.Draw(img)
    w, h = img.size
    for poly, color in redactions:
        pts = [(x * w, y * h) for x, y in (transform(poly) if transform else poly)]
        if color == "blur" and img.mode != "1":
            _blur_polygon(img, pts)
        else:                                   # 1-bit pages can't be blurred: black instead
            draw.polygon(pts, fill=_fill(img, "black" if color == "blur" else color))
    return img


def _blur_polygon(img: Image.Image, pts: list[tuple[float, float]]) -> None:
    """Frosted-glass blur, strong enough that text inside can't be read.

    The area is first shrunk to a few coarse cells (that is what destroys the detail),
    then enlarged and smoothed so it looks like frosted glass rather than mosaic.
    """
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    l, t = max(0, int(min(xs))), max(0, int(min(ys)))
    r, b = min(img.width, int(max(xs)) + 1), min(img.height, int(max(ys)) + 1)
    bw, bh = r - l, b - t
    if bw < 2 or bh < 2:
        return
    region = img.crop((l, t, r, b))
    cell = max(24, min(bw, bh) / 1.5)            # one cell ≈ a character or more
    small = region.resize((max(1, round(bw / cell)), max(1, round(bh / cell))), Image.BOX)
    frosted = small.resize((bw, bh), Image.BICUBIC)
    frosted = frosted.filter(ImageFilter.GaussianBlur(max(4, min(bw, bh) * 0.12)))
    mask = Image.new("L", (bw, bh), 0)
    ImageDraw.Draw(mask).polygon([(x - l, y - t) for x, y in pts], fill=255)
    img.paste(frosted, (l, t), mask)


def rotate_crop(crop: tuple[float, float, float, float], degrees: int) -> tuple[float, float, float, float]:
    l, t, r, b = crop
    for _ in range((degrees // 90) % 4):          # one counter-clockwise quarter turn each
        l, t, r, b = t, 1 - r, b, 1 - l
    return (l, t, r, b)


def _white(img: Image.Image):
    return 255 if img.mode in ("L", "1") else (255, 255, 255)


def geometry(img: Image.Image, e: Edits) -> Image.Image:
    """Apply rotation and straightening (the frame the crop rectangle refers to)."""
    if e.rotate % 360:
        img = img.rotate(e.rotate % 360, expand=True)
    if abs(e.angle) > 0.01:
        src = img.convert("L") if img.mode == "1" else img
        img = src.rotate(e.angle, resample=Image.BICUBIC, expand=False, fillcolor=_white(src))
    return img


def crop_box(size: tuple[int, int], crop) -> tuple[int, int, int, int]:
    w, h = size
    l, t, r, b = crop
    box = (round(l * w), round(t * h), round(r * w), round(b * h))
    return (box[0], box[1], max(box[0] + 1, box[2]), max(box[1] + 1, box[3]))


def tone(img: Image.Image, e: Edits) -> Image.Image:
    if img.mode == "1" or (abs(e.brightness - 1) < 0.01 and abs(e.contrast - 1) < 0.01):
        return img
    if abs(e.brightness - 1) >= 0.01:
        img = ImageEnhance.Brightness(img).enhance(e.brightness)
    if abs(e.contrast - 1) >= 0.01:
        img = ImageEnhance.Contrast(img).enhance(e.contrast)
    return img


def apply(img: Image.Image, e: Edits) -> Image.Image:
    if e.is_identity:
        return img
    was_bw = img.mode == "1"
    size = img.size
    # 1. burn redactions into the original: the covered pixels are gone before anything else
    out = paint_redactions(img, e.redactions)
    out = geometry(out, e)
    if e.crop != FULL:
        out = out.crop(crop_box(out.size, e.crop))
    out = tone(out, e)
    if e.redactions:
        # 2. paint once more on the result, so brightness/contrast/resampling can't grey them
        l, t, r, b = e.crop
        def final(poly):
            return [((x - l) / (r - l), (y - t) / (b - t)) for x, y in to_frame(poly, size, e)]
        solid = tuple(rd for rd in e.redactions if rd[1] != "blur")
        out = paint_redactions(out, solid, final)
    if was_bw and out.mode != "1":
        out = out.point(lambda v: 255 if v > 128 else 0).convert("1")
    return out


def content_box(img: Image.Image, margin: float = 0.01) -> tuple[float, float, float, float]:
    """Find the document on the (white) scanner background, as a normalised crop."""
    small = img.convert("L")
    small.thumbnail((600, 600))
    a = np.asarray(small, dtype=np.int16)
    h, w = a.shape
    edge = 6                                       # ignore the very border (lid shadow)
    inner = a[edge:h - edge, edge:w - edge]
    dark = inner < 225
    # rows/cols with a meaningful amount of non-white pixels
    rows = np.flatnonzero(dark.mean(axis=1) > 0.004)
    cols = np.flatnonzero(dark.mean(axis=0) > 0.004)
    if rows.size == 0 or cols.size == 0:
        return FULL
    t, b = (rows[0] + edge) / h, (rows[-1] + 1 + edge) / h
    l, r = (cols[0] + edge) / w, (cols[-1] + 1 + edge) / w
    return (float(max(0.0, l - margin)), float(max(0.0, t - margin)),
            float(min(1.0, r + margin)), float(min(1.0, b + margin)))
