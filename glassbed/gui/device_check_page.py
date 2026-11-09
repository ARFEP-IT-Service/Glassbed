"""In-window view "Check device": runs glassbed.device_check and shows the report to copy."""
from __future__ import annotations

from PySide6.QtCore import Qt, Signal
from PySide6.QtGui import QFontDatabase, QGuiApplication
from PySide6.QtWidgets import (QHBoxLayout, QLabel, QPlainTextEdit, QProgressBar, QPushButton,
                               QVBoxLayout, QWidget)

from .. import device_check
from ..i18n import tr
from .worker import run_task

HINT = ("Send this report to the developer if the device does not work with Glassbed. "
        "It contains the device's address, model and supported protocols – nothing else.")


class DeviceCheckPage(QWidget):
    closed = Signal()

    def __init__(self, host: str, check=device_check.run_check, parent=None):
        super().__init__(parent)
        title = QLabel(tr("Device check"))
        title.setObjectName("wordmark")
        host_lbl = QLabel(host)
        host_lbl.setObjectName("data")
        self.busy = QLabel(tr("Checking the device…"))
        self.progress = QProgressBar()
        self.progress.setRange(0, 0)
        self.progress.setTextVisible(False)
        self.report = QPlainTextEdit()
        self.report.setReadOnly(True)
        self.report.setFont(QFontDatabase.systemFont(QFontDatabase.SystemFont.FixedFont))
        self.report.setLineWrapMode(QPlainTextEdit.LineWrapMode.WidgetWidth)
        self.report.hide()
        hint = QLabel(tr(HINT))
        hint.setObjectName("hint")
        hint.setWordWrap(True)
        self.copy_btn = QPushButton(tr("Copy report"))
        self.copy_btn.setObjectName("primary")
        self.copy_btn.setEnabled(False)
        self.copy_btn.clicked.connect(self.copy)
        self.copied = QLabel("")
        self.copied.setObjectName("hint")
        done = QPushButton(tr("Done"))
        done.clicked.connect(self.closed.emit)

        buttons = QHBoxLayout()
        buttons.addWidget(self.copy_btn)
        buttons.addWidget(self.copied)
        buttons.addStretch()
        buttons.addWidget(done)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(40, 28, 40, 28)
        lay.setSpacing(10)
        head = QHBoxLayout()
        head.addWidget(title)
        head.addSpacing(12)
        head.addWidget(host_lbl, 0, Qt.AlignmentFlag.AlignBottom)
        head.addStretch()
        lay.addLayout(head)
        lay.addWidget(self.busy)
        lay.addWidget(self.progress)
        lay.addWidget(self.report, 1)
        lay.addWidget(hint)
        lay.addLayout(buttons)

        run_task(lambda _p: device_check.build_report(check(host)), on_done=self.show_report,
                 on_error=lambda e: self.show_report(f"Glassbed device check\nHost: {host}\nError: {e}"))

    def show_report(self, text: str) -> None:
        self.busy.hide()
        self.progress.hide()
        self.report.setPlainText(text)
        self.report.show()
        self.copy_btn.setEnabled(True)

    def copy(self) -> None:
        QGuiApplication.clipboard().setText(self.report.toPlainText())
        self.copied.setText(tr("Copied."))
