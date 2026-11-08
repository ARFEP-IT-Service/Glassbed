"""A question shown on top of the main window (dimmed background) – no popup window."""
from __future__ import annotations

from typing import Callable

from PySide6.QtCore import QEvent, Qt
from PySide6.QtGui import QColor, QKeySequence, QPainter, QShortcut
from PySide6.QtWidgets import QHBoxLayout, QLabel, QPushButton, QVBoxLayout, QWidget


class ConfirmOverlay(QWidget):
    """``buttons``: (label, role, callback) with role "primary", "danger" or "" – Esc cancels.

    ``link``: optional (label, url) shown under the text; opens in the browser when clicked.
    """

    def __init__(self, host: QWidget, title: str, body: str,
                 buttons: list[tuple[str, str, Callable[[], None]]], on_cancel: Callable[[], None],
                 link: tuple[str, str] | None = None):
        super().__init__(host)
        self._on_cancel = on_cancel
        card = QWidget()
        card.setObjectName("sidebar_r")
        card.setMinimumWidth(520)
        card.setMaximumWidth(680)
        heading = QLabel(title)
        heading.setObjectName("wordmark")
        text = QLabel(body)
        text.setWordWrap(True)
        # wrapped labels don't report their height: reserve it for the narrowest card
        text.ensurePolished()
        text.setMinimumHeight(text.heightForWidth(card.minimumWidth() - 56) + 2)
        row = QHBoxLayout()
        row.addStretch()
        for label, role, callback in buttons:
            b = QPushButton(label)
            if role:
                b.setObjectName(role)
            b.setCursor(Qt.CursorShape.PointingHandCursor)
            b.clicked.connect(lambda _=False, cb=callback: self._choose(cb))
            b.ensurePolished()
            hint = b.sizeHint()
            b.setMinimumSize(hint.width() + 16, max(hint.height(), 38))
            row.addWidget(b)
            if role == "primary":
                b.setDefault(True)
                b.setFocus()
        lay = QVBoxLayout(card)
        lay.setContentsMargins(28, 24, 28, 22)
        lay.setSpacing(10)
        lay.addWidget(heading)
        lay.addWidget(text)
        self.link = None
        if link:
            from .widgets import LinkLabel
            self.link = LinkLabel(*link)
            lay.addWidget(self.link)
        lay.addSpacing(10)
        lay.addLayout(row)
        outer = QVBoxLayout(self)
        outer.addStretch()
        outer.addWidget(card, 0, Qt.AlignmentFlag.AlignHCenter)
        outer.addStretch()
        QShortcut(QKeySequence(Qt.Key.Key_Escape), self, self.cancel)
        host.installEventFilter(self)
        self.setGeometry(host.rect())
        self.raise_()
        self.show()

    def eventFilter(self, obj, event) -> bool:
        if event.type() == QEvent.Type.Resize:
            self.setGeometry(obj.rect())
        return False

    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        p.fillRect(self.rect(), QColor(0, 0, 0, 150))
        p.end()

    def mousePressEvent(self, e) -> None:       # clicks on the dimmed area do nothing
        e.accept()

    def _choose(self, callback) -> None:
        self._dismiss()
        callback()

    def cancel(self) -> None:
        self._dismiss()
        self._on_cancel()

    def _dismiss(self) -> None:
        self.parentWidget().removeEventFilter(self)
        self.hide()
        self.deleteLater()
