"""High-level printing: render pages and send them to an IPP printer."""
from __future__ import annotations

from io import BytesIO
from typing import Callable, Sequence

from . import urf
from .ipp import IppError, IppPrinter
from .render import PRINT_DPI, PageRef, render_for_print


def print_pages(ipp_uri: str, pages: Sequence[PageRef], *, media: str = "iso_a4_210x297mm",
                color: bool = True, copies: int = 1, job_name: str = "Glassbed",
                progress: Callable[[int, int], None] | None = None) -> None:
    """Print pages as one job (Apple raster), or page-by-page JPEG as a fallback."""
    if not pages:
        return
    printer = IppPrinter(ipp_uri)
    try:
        formats = printer.get_info().formats
    except (IppError, OSError):
        formats = []
    total = len(pages)

    if not formats or "image/urf" in formats:
        rendered = (render_for_print(p, media, color) for p in pages)
        data = urf.encode_document(rendered, total, PRINT_DPI, color,
                                   progress=(lambda i: progress(i, total)) if progress else None)
        printer.print_document(data, "image/urf", job_name, copies, media, color)
        return

    if "image/jpeg" in formats:
        for i, p in enumerate(pages, 1):
            buf = BytesIO()
            render_for_print(p, media, color).save(buf, "JPEG", quality=92, dpi=(PRINT_DPI, PRINT_DPI))
            printer.print_document(buf.getvalue(), "image/jpeg", f"{job_name} ({i}/{total})",
                                   copies, media, color)
            if progress:
                progress(i, total)
        return

    raise IppError("The printer supports neither Apple raster (URF) nor JPEG")
