"""Visual identity: "proof sheet" – the app as a print shop's proofing desk.

Pages lie on a scanner platen like paper on glass, the CMYK process colours of the
toner are the only accents, and data (dpi, IP, page numbers, toner %) is set in mono.
"""
from __future__ import annotations

import os
from pathlib import Path

from PySide6.QtCore import Qt
from PySide6.QtGui import QColor, QFont, QFontDatabase, QPalette
from PySide6.QtWidgets import QApplication

# Process colours – used for the registration stripe, selection and states.
CYAN = "#00A3D9"
MAGENTA = "#E5007E"
YELLOW = "#FFD400"
KEY = "#15181B"

DARK = {
    "platen": "#111316",     # the glass the pages lie on
    "surface": "#1B1E22",    # lid / panels
    "raised": "#24282D",     # fields and buttons
    "line": "#30353B",
    "text": "#E9ECEF",
    "muted": "#8B939C",
    "paper": "#FFFFFF",
    "shadow": "#000000",
    "primary_bg": "#F3F5F6",  # main action is a white sheet
    "primary_fg": "#111316",
    "primary_hover": "#FFFFFF",
    "accent": "#1581FF",              # ARFEP brand blue
    "accent_soft": "rgba(21, 129, 255, 0.20)",
    "danger": "#FF4FA8",
}

LIGHT = {
    "platen": "#DDE2E6",
    "surface": "#F7F8F9",
    "raised": "#FFFFFF",
    "line": "#CBD2D8",
    "text": "#15181B",
    "muted": "#5B646D",
    "paper": "#FFFFFF",
    "shadow": "#36404A",
    "primary_bg": "#212830",  # main action in ARFEP ink
    "primary_fg": "#FFFFFF",
    "primary_hover": "#1A2027",
    "accent": "#0A5FCC",              # ARFEP blue, darker for contrast on light backgrounds
    "accent_soft": "rgba(10, 95, 204, 0.12)",
    "danger": MAGENTA,
}

T: dict[str, str] = dict(DARK)


def _first_family(*names: str) -> str:
    available = set(QFontDatabase.families())
    return next((n for n in names if n in available), names[-1])


DISPLAY = BODY = MONO = ""


def dark() -> bool:
    return T.get("platen") == DARK["platen"]


def display_font(pt: float, weight: QFont.Weight = QFont.Weight.DemiBold) -> QFont:
    f = QFont(DISPLAY)
    f.setPointSizeF(pt)
    f.setWeight(weight)
    return f


def mono_font(pt: float) -> QFont:
    f = QFont(MONO)
    f.setPointSizeF(pt)
    return f


STYLE = """
* {{ outline: none; }}
QWidget {{ color: {text}; font-family: "{body}"; font-size: 10pt; }}
QMainWindow, QWidget#root {{ background: {platen}; }}
QWidget#header, QWidget#sidebar, QWidget#outbar {{ background: {surface}; }}
QWidget#sidebar {{ border-right: 1px solid {line}; }}
QWidget#outbar {{ border-top: 1px solid {line}; }}
QWidget#toolbar {{ background: {platen}; }}

QPushButton#byline {{
    background: transparent; border: none; padding: 0 0 4px 6px; color: {muted};
    font-family: "{mono}"; font-size: 8pt;
}}
QPushButton#byline:hover {{ color: {accent}; }}
QWidget#divider {{ background: {line}; }}
QLabel#wordmark {{ font-family: "{display}"; font-size: 15pt; font-weight: 600; letter-spacing: 0.5px; }}
QLabel#eyebrow {{ font-family: "{display}"; font-size: 8.5pt; padding-top: 2px; color: {muted}; letter-spacing: 1.6px; }}
QLabel#hint {{ color: {muted}; font-size: 9pt; }}
QLabel#data, QLabel#count {{ font-family: "{mono}"; font-size: 9pt; color: {muted}; }}
QLabel#status {{ font-family: "{mono}"; font-size: 9pt; }}

QPushButton, QToolButton {{
    background: {raised}; border: 1px solid {line}; border-radius: 6px;
    padding: 6px 12px; color: {text};
}}
QPushButton:hover, QToolButton:hover {{ border-color: {muted}; }}
QPushButton:focus, QToolButton:focus {{ border-color: {accent}; }}
QPushButton:disabled, QToolButton:disabled {{ color: {muted}; background: transparent; border-color: {line}; }}
QToolButton {{ background: transparent; border-color: transparent; }}
QToolButton:hover {{ background: {raised}; border-color: {line}; }}
QToolButton#icon {{ font-size: 13pt; padding: 2px 8px; color: {muted};
                    font-family: "Segoe UI Symbol", "Noto Sans Symbols 2", "{body}"; }}
QPushButton#toastaction {{
    background: {primary_bg}; color: {primary_fg}; border: none; border-radius: 6px;
    padding: 8px 16px; font-weight: 600;
}}
QPushButton#toastaction:hover {{ background: {primary_hover}; }}
QToolButton#icon:hover {{ color: {text}; }}
QToolButton:disabled {{ background: transparent; border-color: transparent; }}

QPushButton#primary {{
    background: {primary_bg}; color: {primary_fg}; border: none; border-radius: 4px;
    font-family: "{display}"; font-size: 12pt; font-weight: 600; padding: 12px 20px;
    letter-spacing: 0.4px;
}}
QPushButton#primary:hover {{ background: {primary_hover}; }}
QPushButton#primary:focus {{ border: 2px solid {accent}; }}
QPushButton#primary:disabled {{ background: {line}; color: {muted}; }}
QPushButton#danger {{ color: {danger}; border-color: {danger}; background: transparent; }}

QPushButton#tab {{
    background: transparent; border: none; border-radius: 0; padding: 14px 4px 11px 4px;
    margin: 0 10px; font-family: "{display}"; font-size: 12pt; color: {muted};
    border-bottom: 3px solid transparent;
}}
QPushButton#tab:hover {{ color: {text}; }}
QPushButton#tab:checked {{ color: {text}; border-bottom-color: {text}; }}

QPushButton[seg] {{ border-radius: 0; padding: 7px 6px; margin: 0; background: {raised}; }}
QPushButton[seg="first"] {{ border-top-left-radius: 6px; border-bottom-left-radius: 6px; }}
QPushButton[seg="last"] {{ border-top-right-radius: 6px; border-bottom-right-radius: 6px; }}
QPushButton[seg="only"] {{ border-radius: 6px; }}
QPushButton[seg]:checked {{ background: {accent_soft}; border-color: {accent}; color: {text}; font-weight: 600; }}
QPushButton[seg]:disabled {{ color: {line}; }}

QComboBox, QLineEdit, QSpinBox {{
    background: {raised}; border: 1px solid {line}; border-radius: 6px; padding: 5px 8px;
    selection-background-color: {accent};
}}
QComboBox:hover, QLineEdit:hover, QSpinBox:hover {{ border-color: {muted}; }}
QComboBox:focus, QLineEdit:focus, QSpinBox:focus {{ border-color: {accent}; }}
QComboBox::drop-down {{ border: none; width: 26px; }}
QComboBox::down-arrow {{ image: url({assets}/chevron-down-{scheme}.svg); width: 12px; height: 12px; }}
QComboBox:editable {{ padding-right: 4px; }}
QComboBox QAbstractItemView {{
    background: {raised}; border: 1px solid {line}; selection-background-color: {accent_soft};
    selection-color: {text}; padding: 4px;
}}
QSpinBox {{ padding: 5px 22px 5px 8px; }}
QLabel#stepvalue {{
    background: {raised}; border-top: 1px solid {line}; border-bottom: 1px solid {line};
    font-family: "{mono}"; font-size: 11pt; padding: 5px 0;
}}
QPushButton#stepbtn {{ font-size: 12pt; padding: 3px 0; }}
QPlainTextEdit#filename {{
    background: {raised}; border: 1px solid {line}; border-radius: 6px; padding: 3px 5px;
    selection-background-color: {accent};
}}
QPlainTextEdit#filename:hover {{ border-color: {muted}; }}
QPlainTextEdit#filename:focus {{ border-color: {accent}; }}
QPushButton#picker {{ text-align: left; padding: 0; background: {raised}; }}
QPushButton#picker[missing="true"] {{ border: 1px dashed {accent}; }}
QLabel#pickername {{ font-weight: 600; background: transparent; }}
QLabel#pickerpath {{ color: {muted}; font-family: "{mono}"; font-size: 8pt; background: transparent; }}
QLabel#saved {{ color: {muted}; font-size: 9pt; }}
QWidget#sidebar_r {{ background: {surface}; border-left: 1px solid {line}; }}
QSlider::groove:horizontal {{ height: 4px; background: {line}; border-radius: 2px; }}
QSlider::sub-page:horizontal {{ background: {accent}; border-radius: 2px; }}
QSlider::handle:horizontal {{
    width: 14px; height: 14px; margin: -6px 0; border-radius: 7px;
    background: {text}; border: 2px solid {surface};
}}
QSlider::handle:horizontal:hover {{ background: {accent}; }}
QSlider:focus {{ outline: none; }}
QWidget#zoombar {{ background: {surface}; border: 1px solid {line}; border-radius: 8px; }}
QWidget#zoombar QToolButton {{ font-size: 12pt; padding: 2px 9px; }}
QLabel#zoomicon {{ color: {muted}; font-size: 11pt; }}
QComboBox#lang {{ font-family: "{mono}"; font-size: 9pt; padding: 3px 6px; min-width: 34px; }}
QSpinBox::up-button, QSpinBox::down-button {{ width: 20px; border: none; background: transparent; }}
QSpinBox::up-arrow {{ image: url({assets}/chevron-up-{scheme}.svg); width: 10px; height: 10px; }}
QSpinBox::down-arrow {{ image: url({assets}/chevron-down-{scheme}.svg); width: 10px; height: 10px; }}

QCheckBox {{ spacing: 8px; }}
QCheckBox::indicator {{ width: 14px; height: 14px; border: 1px solid {muted}; border-radius: 3px; background: {raised}; }}
QCheckBox::indicator:checked {{ background: {accent}; border-color: {accent}; image: url({assets}/check.svg); }}
QCheckBox::indicator:focus {{ border-color: {accent}; }}

QListWidget {{ background: transparent; border: none; }}
QListWidget#files {{ background: {surface}; border: 1px solid {line}; border-radius: 6px; padding: 2px; }}
QListWidget#files::item {{ padding: 5px 8px; border-radius: 4px; }}
QListWidget#files::item:selected {{ background: {accent_soft}; color: {text}; }}

QProgressBar {{ background: {line}; border: none; border-radius: 2px; max-height: 4px; }}
QProgressBar::chunk {{ background: {accent}; border-radius: 2px; }}

QStatusBar {{ background: {surface}; color: {muted}; border-top: 1px solid {line};
              font-family: "{mono}"; font-size: 9pt; }}
QStatusBar::item {{ border: none; }}

QScrollBar:vertical {{ background: transparent; width: 10px; margin: 2px; }}
QScrollBar::handle:vertical {{ background: {line}; border-radius: 3px; min-height: 30px; }}
QScrollBar::handle:vertical:hover {{ background: {muted}; }}
QScrollBar::add-line, QScrollBar::sub-line, QScrollBar::add-page, QScrollBar::sub-page {{ height: 0; background: none; }}
QScrollBar:horizontal {{ height: 0; }}

QToolTip {{ background: {raised}; color: {text}; border: 1px solid {line}; padding: 5px 8px; }}
QDialog {{ background: {surface}; }}
"""


def is_dark(app: QApplication) -> bool:
    forced = os.environ.get("GLASSBED_THEME", "").lower()
    if forced not in ("dark", "light"):
        from .. import config
        forced = str(config.settings().value("ui/theme", "system"))
    if forced in ("dark", "light"):
        return forced == "dark"
    scheme = app.styleHints().colorScheme()
    if scheme == Qt.ColorScheme.Unknown:
        return app.palette().window().color().lightness() < 128
    return scheme == Qt.ColorScheme.Dark


def apply(app: QApplication) -> None:
    global DISPLAY, BODY, MONO
    DISPLAY = _first_family("Bahnschrift", "DIN Alternate", "Barlow", "Roboto Condensed", "Sans Serif")
    BODY = _first_family("Segoe UI Variable Text", "Segoe UI", "SF Pro Text", "Inter", "Cantarell", "Sans Serif")
    MONO = _first_family("Cascadia Mono", "SF Mono", "JetBrains Mono", "DejaVu Sans Mono", "Monospace")

    T.clear()
    T.update(DARK if is_dark(app) else LIGHT)

    pal = QPalette()
    for role, key in ((QPalette.ColorRole.Window, "surface"), (QPalette.ColorRole.Base, "raised"),
                      (QPalette.ColorRole.AlternateBase, "surface"), (QPalette.ColorRole.Button, "raised"),
                      (QPalette.ColorRole.WindowText, "text"), (QPalette.ColorRole.Text, "text"),
                      (QPalette.ColorRole.ButtonText, "text"), (QPalette.ColorRole.ToolTipBase, "raised"),
                      (QPalette.ColorRole.ToolTipText, "text"), (QPalette.ColorRole.Mid, "line"),
                      (QPalette.ColorRole.PlaceholderText, "muted")):
        pal.setColor(role, QColor(T[key]))
    pal.setColor(QPalette.ColorRole.Highlight, QColor(T["accent"]))
    pal.setColor(QPalette.ColorRole.HighlightedText, QColor("#FFFFFF"))
    pal.setColor(QPalette.ColorGroup.Disabled, QPalette.ColorRole.Text, QColor(T["muted"]))
    pal.setColor(QPalette.ColorGroup.Disabled, QPalette.ColorRole.ButtonText, QColor(T["muted"]))
    app.setPalette(pal)
    assets = (Path(__file__).resolve().parent.parent / "assets").as_posix()
    app.setStyleSheet(STYLE.format(display=DISPLAY, body=BODY, mono=MONO, assets=assets,
                                   scheme="dark" if dark() else "light", **T))
