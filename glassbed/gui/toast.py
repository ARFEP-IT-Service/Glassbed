"""In-window banner for confirmations, errors and questions – no popup windows."""
from __future__ import annotations

from pathlib import Path
from typing import Callable

from PySide6.QtCore import QEasingCurve, QPoint, QPropertyAnimation, Qt, QTimer
from PySide6.QtWidgets import (QFrame, QGraphicsDropShadowEffect, QHBoxLayout, QLabel,
                               QPushButton, QToolButton, QVBoxLayout, QWidget)

from ..i18n import tr
from . import theme
from .files import open_file, reveal

ICONS = {"ok": "✓", "error": "!", "info": "i", "question": "?"}


class Toast(QFrame):
    SHOW_MS = 9000
    SIDE = 290        # keep clear of the sidebars

    def __init__(self, host: QWidget):
        super().__init__(host)
        self.setObjectName("toast")
        self._path: Path | None = None
        self._action: Callable[[], None] | None = None
        self._sticky = False

        self.icon = QLabel()
        self.icon.setObjectName("toasticon")
        self.icon.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.icon.setFixedSize(30, 30)
        self.title = QLabel()
        self.title.setObjectName("toasttitle")
        self.detail = QLabel()
        self.detail.setObjectName("toastdetail")
        self.body = QLabel()
        self.body.setObjectName("toastbody")
        self.body.setWordWrap(True)
        text = QVBoxLayout()
        text.setSpacing(2)
        text.addWidget(self.title)
        text.addWidget(self.detail)
        text.addWidget(self.body)

        self.open_btn = QPushButton(tr("Open"))
        self.open_btn.clicked.connect(lambda: self._path and open_file(self._path))
        self.reveal_btn = QPushButton(tr("Show in folder"))
        self.reveal_btn.clicked.connect(lambda: self._path and reveal(self._path))
        self.action_btn = QPushButton()
        self.action_btn.setObjectName("toastaction")
        self.action_btn.clicked.connect(self._run_action)
        close = QToolButton()
        close.setText("✕")
        close.setObjectName("icon")
        close.clicked.connect(self.dismiss)

        lay = QHBoxLayout(self)
        lay.setContentsMargins(14, 10, 10, 10)
        lay.setSpacing(12)
        lay.addWidget(self.icon, 0, Qt.AlignmentFlag.AlignTop)
        lay.addLayout(text, 1)
        lay.addWidget(self.open_btn)
        lay.addWidget(self.reveal_btn)
        lay.addWidget(self.action_btn)
        lay.addWidget(close, 0, Qt.AlignmentFlag.AlignTop)

        shadow = QGraphicsDropShadowEffect(self)
        shadow.setBlurRadius(28)
        shadow.setOffset(0, 6)
        shadow.setColor(Qt.GlobalColor.black)
        self.setGraphicsEffect(shadow)

        self._timer = QTimer(self, singleShot=True)
        self._timer.timeout.connect(self.dismiss)
        self._anim = QPropertyAnimation(self, b"pos", self)
        self._anim.setDuration(220)
        self._anim.setEasingCurve(QEasingCurve.Type.OutCubic)
        self.hide()

    def show_message(self, title: str, detail: str = "", path: Path | None = None, *,
                     kind: str = "ok", body: str = "",
                     action: tuple[str, Callable[[], None]] | None = None) -> None:
        """kind: ok / error / info / question. Errors and questions stay until closed."""
        self._path = path
        self._action = action[1] if action else None
        self._sticky = kind in ("error", "question")
        self.title.setText(title)
        self.body.setText(body)
        self.body.setVisible(bool(body))
        self.icon.setText(ICONS.get(kind, "✓"))
        self.setProperty("kind", kind)
        for w in (self, self.icon):
            w.style().unpolish(w)
            w.style().polish(w)
        self.open_btn.setVisible(path is not None)
        self.reveal_btn.setVisible(path is not None)
        self.action_btn.setVisible(action is not None)
        if action:
            self.action_btn.setText(action[0])

        x, area_w = self._area()
        width = min(640 if body else max(self.sizeHint().width(), 380), area_w)
        # long file names: shorten in the middle so the extension and size stay visible
        buttons = sum(b.sizeHint().width() + 12 for b in (self.open_btn, self.reveal_btn, self.action_btn)
                      if not b.isHidden())
        room = width - buttons - 140
        name, sep, rest = detail.partition("  ·  ")
        fm = self.detail.fontMetrics()
        tail = sep + rest
        name = fm.elidedText(name, Qt.TextElideMode.ElideMiddle, max(60, room - fm.horizontalAdvance(tail)))
        self.detail.setText(name + tail)
        self.detail.setToolTip(detail)
        self.detail.setVisible(bool(detail))
        self.setFixedWidth(width)
        # height: measure the wrapped text column ourselves (QLabel word wrap needs a width)
        lay = self.layout()
        margins = lay.contentsMargins()
        visible = [b for b in (self.open_btn, self.reveal_btn, self.action_btn) if not b.isHidden()]
        text_w = (width - margins.left() - margins.right() - self.icon.width() - 28
                  - sum(b.sizeHint().width() for b in visible) - lay.spacing() * (2 + len(visible)))
        h = self.title.sizeHint().height()
        if detail:
            h += 2 + self.detail.sizeHint().height()
        if body:
            h += 2 + self.body.heightForWidth(max(120, text_w))
        self.setFixedHeight(max(50, h + margins.top() + margins.bottom()))

        x += (area_w - width) // 2
        bottom = self.parentWidget().height() - self.height() - 18
        was_visible = self.isVisible()
        self.raise_()
        self.show()
        self._anim.stop()
        self._anim.setStartValue(self.pos() if was_visible else QPoint(x, bottom + 40))
        self._anim.setEndValue(QPoint(x, bottom))
        self._anim.start()
        if self._sticky:
            self._timer.stop()
        else:
            self._timer.start(self.SHOW_MS)

    def _run_action(self) -> None:
        action = self._action
        self.dismiss()
        if action:
            action()

    def _area(self) -> tuple[int, int]:
        """Horizontal span of the platen between the sidebars (or the whole window if narrow)."""
        w = self.parentWidget().width()
        side = self.SIDE if w - 2 * self.SIDE >= 380 else 20
        return side, w - 2 * side

    def dismiss(self) -> None:
        self._timer.stop()
        self.hide()

    def reposition(self) -> None:
        if self.isVisible():
            x, width = self._area()
            self.move(x + (width - self.width()) // 2, self.parentWidget().height() - self.height() - 18)

    def enterEvent(self, e) -> None:          # keep it open while the mouse is on it
        self._timer.stop()
        super().enterEvent(e)

    def leaveEvent(self, e) -> None:
        if not self._sticky:
            self._timer.start(3000)
        super().leaveEvent(e)


STYLE = """
QFrame#toast {{ background: {raised}; border: 1px solid {line}; border-left: 4px solid {accent};
                border-radius: 8px; }}
QFrame#toast[kind="error"] {{ border-left-color: {danger}; }}
QLabel#toasticon {{ background: {accent}; color: white; border-radius: 15px;
                    font-size: 13pt; font-weight: 700; }}
QFrame#toast[kind="error"] QLabel#toasticon {{ background: {danger}; }}
QLabel#toasttitle {{ font-family: "{display}"; font-size: 12pt; font-weight: 600; background: transparent; }}
QLabel#toastdetail {{ font-family: "{mono}"; font-size: 9pt; color: {muted}; background: transparent; }}
QLabel#toastbody {{ color: {text}; background: transparent; }}
"""


def style() -> str:
    return STYLE.format(display=theme.DISPLAY, mono=theme.MONO, **theme.T)
