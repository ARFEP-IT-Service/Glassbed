"""Turn PDFs, images and scans into printer-ready page bitmaps."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image, ImageOps

try:
    import pypdfium2 as pdfium
except ImportError:  # pragma: no cover - PDF support is optional at import time
    pdfium = None

PRINT_DPI = 300
IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".bmp", ".gif", ".tif", ".tiff", ".webp"}
SUPPORTED_EXTENSIONS = IMAGE_EXTENSIONS | {".pdf"}

# IPP media keyword -> size in millimetres
MEDIA = {
    "iso_a4_210x297mm": (210.0, 297.0),
    "na_letter_8.5x11in": (215.9, 279.4),
    "na_legal_8.5x14in": (215.9, 355.6),
    "iso_a5_148x210mm": (148.0, 210.0),
}


def media_pixels(media: str, dpi: int = PRINT_DPI) -> tuple[int, int]:
    w_mm, h_mm = MEDIA[media]
    return round(w_mm / 25.4 * dpi), round(h_mm / 25.4 * dpi)


@dataclass
class PageRef:
    """One printable page: a page of a PDF, an image file or an in-memory scan."""
    path: Path | None = None
    index: int = 0
    image: Image.Image | None = None
    dpi: int | None = None          # known physical resolution (scans)

    @property
    def is_pdf(self) -> bool:
        return self.path is not None and self.path.suffix.lower() == ".pdf"

    @property
    def label(self) -> str:
        if self.path is None:
            return "Scan"
        return f"{self.path.name} – {self.index + 1}" if self.is_pdf else self.path.name


def open_document(path: str | Path) -> list[PageRef]:
    path = Path(path)
    ext = path.suffix.lower()
    if ext == ".pdf":
        if pdfium is None:
            raise RuntimeError("pypdfium2 is required for PDF support")
        pdf = pdfium.PdfDocument(str(path))
        try:
            return [PageRef(path=path, index=i) for i in range(len(pdf))]
        finally:
            pdf.close()
    if ext in IMAGE_EXTENSIONS:
        with Image.open(path) as im:
            frames = getattr(im, "n_frames", 1)
        return [PageRef(path=path, index=i) for i in range(frames)]
    raise ValueError(f"Unsupported file type: {path.name}")


def _load_image(ref: PageRef) -> tuple[Image.Image, float | None]:
    """Return the page image and its dpi (None if unknown)."""
    if ref.image is not None:
        return ref.image, ref.dpi
    with Image.open(ref.path) as im:
        if getattr(im, "n_frames", 1) > 1:
            im.seek(ref.index)
        img = ImageOps.exif_transpose(im.copy())
        dpi = im.info.get("dpi", (None,))[0]
    return img, (float(dpi) if dpi and dpi > 1 else None)


def render(ref: PageRef, dpi: int) -> Image.Image:
    """Render a page at the given dpi (images are returned at native size)."""
    if ref.is_pdf:
        pdf = pdfium.PdfDocument(str(ref.path))
        try:
            page = pdf[ref.index]
            img = page.render(scale=dpi / 72).to_pil()
            page.close()
            return img
        finally:
            pdf.close()
    return _load_image(ref)[0]


def thumbnail(ref: PageRef, size: int = 220) -> Image.Image:
    if ref.is_pdf:
        pdf = pdfium.PdfDocument(str(ref.path))
        try:
            page = pdf[ref.index]
            w, h = page.get_size()
            img = page.render(scale=size / max(w, h)).to_pil()
            page.close()
        finally:
            pdf.close()
    else:
        img = _load_image(ref)[0].copy()
        img.thumbnail((size, size))
    return img.convert("RGB")


def _flatten(img: Image.Image) -> Image.Image:
    if img.mode in ("RGBA", "LA", "P"):
        img = img.convert("RGBA")
        bg = Image.new("RGB", img.size, "white")
        bg.paste(img, mask=img.split()[-1])
        return bg
    return img.convert("RGB")


def render_for_print(ref: PageRef, media: str, color: bool,
                     dpi: int = PRINT_DPI, margin_mm: float = 5.0) -> Image.Image:
    """Produce a full-page bitmap of exactly the media size.

    * PDFs are scaled to fit the page (1:1 when the sizes match).
    * Scans with a known dpi are placed at actual size, top-left (like a copier).
    * Other images are fitted inside the margins, centred.
    Landscape content is rotated when that gives a better fit.
    """
    page_w, page_h = media_pixels(media, dpi)
    canvas = Image.new("RGB", (page_w, page_h), "white")

    if ref.is_pdf:
        pdf = pdfium.PdfDocument(str(ref.path))
        try:
            page = pdf[ref.index]
            pw, ph = page.get_size()
            rotate = (pw > ph) != (page_w > page_h)
            if rotate:
                pw, ph = ph, pw
            scale = min(page_w / (pw / 72 * dpi), page_h / (ph / 72 * dpi))
            img = page.render(scale=dpi / 72 * scale, rotation=90 if rotate else 0).to_pil()
            page.close()
        finally:
            pdf.close()
        img = _flatten(img)
        canvas.paste(img, ((page_w - img.width) // 2, (page_h - img.height) // 2))
    else:
        img, src_dpi = _load_image(ref)
        img = _flatten(img)
        if ref.image is not None and src_dpi:
            # Scan: actual size, anchored top-left like the original on the glass.
            f = dpi / src_dpi
            img = img.resize((round(img.width * f), round(img.height * f)), Image.LANCZOS)
            canvas.paste(img.crop((0, 0, min(img.width, page_w), min(img.height, page_h))), (0, 0))
        else:
            if (img.width > img.height) != (page_w > page_h):
                img = img.rotate(90, expand=True)
            margin = round(margin_mm / 25.4 * dpi)
            box_w, box_h = page_w - 2 * margin, page_h - 2 * margin
            f = min(box_w / img.width, box_h / img.height)
            if src_dpi:  # never upscale beyond the image's physical size
                f = min(f, dpi / src_dpi)
            img = img.resize((max(1, round(img.width * f)), max(1, round(img.height * f))), Image.LANCZOS)
            canvas.paste(img, ((page_w - img.width) // 2, (page_h - img.height) // 2))

    return canvas if color else canvas.convert("L")


def parse_page_range(text: str, page_count: int) -> list[int]:
    """'1-3, 5' -> [0, 1, 2, 4]. Empty text means all pages."""
    text = text.strip()
    if not text:
        return list(range(page_count))
    result: list[int] = []
    for part in text.replace(";", ",").split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            a, b = part.split("-", 1)
            start = int(a) if a.strip() else 1
            end = int(b) if b.strip() else page_count
        else:
            start = end = int(part)
        if start < 1 or end < start:
            raise ValueError(part)
        result.extend(i - 1 for i in range(start, min(end, page_count) + 1))
    return result


# Output quality presets: (max dpi or None to keep, JPEG quality, turn near-grey colour pages grey)
QUALITY = {
    "high": (None, 90, False),
    "normal": (200, 75, False),
    "compact": (150, 60, True),
}


def _is_greyish(img: Image.Image) -> bool:
    """True when a colour page has (almost) no colour – e.g. a black text letter."""
    small = np.asarray(img.convert("RGB").resize((160, 226)), dtype=np.int16)
    chroma = small.max(axis=2) - small.min(axis=2)
    return float(np.percentile(chroma, 99.5)) < 40


def prepare_page(img: Image.Image, dpi: int, quality: str) -> tuple[Image.Image, int]:
    """Downsample / simplify a scanned page for the chosen output quality."""
    max_dpi, _q, auto_grey = QUALITY[quality]
    if img.mode == "1":
        return img, dpi                       # 1-bit is already tiny
    if img.mode not in ("RGB", "L"):
        img = img.convert("RGB")
    if max_dpi and dpi > max_dpi:
        f = max_dpi / dpi
        img = img.resize((max(1, round(img.width * f)), max(1, round(img.height * f))), Image.LANCZOS)
        dpi = max_dpi
    if auto_grey and img.mode == "RGB" and _is_greyish(img):
        img = img.convert("L")
    return img, dpi


def _group(pages: list, split: int) -> list[list]:
    if split <= 0:
        return [pages]
    return [pages[i:i + split] for i in range(0, len(pages), split)]


def planned_paths(path: Path, fmt: str, page_count: int, split: int = 0) -> list[Path]:
    """File names save_pages() will write (to check for collisions beforehand)."""
    fmt = fmt.lower()
    files = page_count if fmt != "pdf" else len(_group(list(range(page_count)), split))
    if files == 1:
        return [path]
    return [path.with_name(f"{path.stem}_{i:02d}{path.suffix}") for i in range(1, files + 1)]


def _write(pages: list[tuple[Image.Image, int]], target: Path, fmt: str, quality: str) -> None:
    jpeg_q = QUALITY[quality][1]
    if fmt == "pdf":
        images = [im for im, _ in pages]
        if all(im.mode == "1" for im in images):
            extra = {}                        # pure 1-bit document: no JPEG involved
        else:
            # Pillow shares one quality setting for the whole file, which 1-bit pages reject.
            images = [im.convert("L") if im.mode == "1" else im for im in images]
            extra = {"quality": jpeg_q}
        images[0].save(target, "PDF", resolution=float(pages[0][1]), save_all=True,
                       append_images=images[1:], **extra)
    elif fmt in ("jpg", "jpeg"):
        im, dpi = pages[0]
        im = im.convert("L") if im.mode == "1" else im
        im.save(target, "JPEG", quality=jpeg_q, dpi=(dpi, dpi))
    else:
        im, dpi = pages[0]
        im.save(target, "PNG", dpi=(dpi, dpi), optimize=quality != "high")


def save_pages(pages: list[tuple[Image.Image, int]], path: Path, fmt: str,
               quality: str = "normal", split: int = 0) -> list[Path]:
    """Save scanned pages.

    ``split``: 0 = one PDF, 1 = one PDF per page, N = one PDF per N pages.
    JPG/PNG always give one file per page.
    """
    fmt = fmt.lower()
    prepared = [prepare_page(im, dpi, quality) for im, dpi in pages]
    groups = _group(prepared, split) if fmt == "pdf" else [[p] for p in prepared]
    targets = planned_paths(path, fmt, len(prepared), split)
    for group, target in zip(groups, targets):
        _write(group, target, fmt, quality)
    return targets


def estimate_size(pages: list[tuple[Image.Image, int]], fmt: str, quality: str,
                  sample: int = 2) -> int:
    """Rough output size in bytes, extrapolated from the first pages."""
    if not pages:
        return 0
    import io
    probe = pages[:sample]
    total = 0
    for im, dpi in probe:
        buf = io.BytesIO()
        img, d = prepare_page(im, dpi, quality)
        if fmt.lower() == "png":
            img.save(buf, "PNG", optimize=False)
        else:
            (img.convert("L") if img.mode == "1" else img).save(buf, "JPEG", quality=QUALITY[quality][1])
        total += len(buf.getvalue())
    return round(total / len(probe) * len(pages))
