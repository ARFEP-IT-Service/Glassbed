"""Render the app icon from glassbed/assets/icon/glassbed.svg (results are committed).

Writes glassbed-<size>.png for 16–512 px and glassbed.ico (16–256 px). The small sizes
(16 and 24 px) are drawn without the folded corner so they stay crisp.
Run:  python tools/make_icon.py
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

from PIL import Image
from PySide6.QtCore import QByteArray, QRectF, Qt
from PySide6.QtGui import QGuiApplication, QImage, QPainter
from PySide6.QtSvg import QSvgRenderer

ICON_DIR = Path(__file__).resolve().parent.parent / "glassbed" / "assets" / "icon"
SVG = ICON_DIR / "glassbed.svg"
SIZES = (16, 24, 32, 48, 64, 128, 256, 512)
ICO_SIZES = (16, 24, 32, 48, 64, 128, 256)
SMALL = (16, 24)                                  # without the folded corner
DOG_EAR = re.compile(r'\s*<path d="M154 44 L154 80 L190 80 Z"[^>]*/>')


def render(svg: str, size: int) -> Image.Image:
    renderer = QSvgRenderer(QByteArray(svg.encode("utf-8")))
    img = QImage(size, size, QImage.Format.Format_ARGB32)
    img.fill(Qt.GlobalColor.transparent)
    painter = QPainter(img)
    painter.setRenderHint(QPainter.RenderHint.Antialiasing)
    renderer.render(painter, QRectF(0, 0, size, size))
    painter.end()
    rgba = img.convertToFormat(QImage.Format.Format_RGBA8888)
    return Image.frombuffer("RGBA", (size, size), bytes(rgba.constBits()), "raw", "RGBA", 0, 1).copy()


_APP = None                                         # Qt needs a living application object to render


def main() -> None:
    global _APP
    _APP = QGuiApplication.instance() or QGuiApplication(sys.argv)
    full = SVG.read_text(encoding="utf-8")
    simple = DOG_EAR.sub("", full)
    assert simple != full, "folded-corner path not found in the SVG"
    images = {}
    for size in SIZES:
        images[size] = render(simple if size in SMALL else full, size)
        images[size].save(ICON_DIR / f"glassbed-{size}.png", optimize=True)
    largest = images[max(ICO_SIZES)]
    largest.save(ICON_DIR / "glassbed.ico", format="ICO", sizes=[(s, s) for s in ICO_SIZES],
                 append_images=[images[s] for s in ICO_SIZES if s != max(ICO_SIZES)])
    print("written:", ", ".join(f"glassbed-{s}.png" for s in SIZES), "+ glassbed.ico")


if __name__ == "__main__":
    main()
