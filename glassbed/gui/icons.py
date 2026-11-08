"""The Glassbed app icon (window, taskbar, tray)."""
from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import QSize
from PySide6.QtGui import QIcon

ICON_DIR = Path(__file__).resolve().parent.parent / "assets" / "icon"
SIZES = (16, 24, 32, 48, 64, 128, 256, 512)

_icon: QIcon | None = None


def app_icon() -> QIcon:
    """All rendered sizes in one QIcon, so Qt picks the sharp one for each place."""
    global _icon
    if _icon is None:
        _icon = QIcon()
        for size in SIZES:
            path = ICON_DIR / f"glassbed-{size}.png"
            if path.exists():
                _icon.addFile(str(path), QSize(size, size))
    return _icon
