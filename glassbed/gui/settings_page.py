"""Settings page (inside the main window): language, appearance, default save folder."""
from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import QSettings, Qt, QUrl, Signal
from PySide6.QtGui import QDesktopServices, QKeySequence, QShortcut
from PySide6.QtWidgets import (QFileDialog, QHBoxLayout, QLabel, QPushButton, QVBoxLayout,
                               QWidget)

from .. import __version__, brand, i18n
from ..i18n import tr
from . import theme
from .widgets import FolderPicker, Segmented, eyebrow, svg_pixmap

THEMES = [("system", "System"), ("light", "Light"), ("dark", "Dark")]


class SettingsPage(QWidget):
    applied = Signal()
    closed = Signal()

    def __init__(self, settings: QSettings, parent=None):
        super().__init__(parent)
        self.settings = settings

        self.language = Segmented([(name, code) for code, name in i18n.LANGUAGES.items()])
        self.language.setCurrentIndex(self.language.findData(i18n.LANG))
        self.appearance = Segmented([(tr(label), key) for key, label in THEMES])
        self.appearance.setCurrentIndex(max(0, self.appearance.findData(settings.value("ui/theme", "system"))))
        self.folder = FolderPicker(tr("Choose folder…"))
        folder = settings.value("scan/folder", "")
        self.folder.set_path(Path(folder) if folder else None)
        self.folder.clicked.connect(self._choose_folder)

        hint = QLabel(tr("Scans are saved here unless you pick another folder in the scan tab."))
        hint.setObjectName("hint")
        hint.setWordWrap(True)
        about = QLabel(f"Glassbed {__version__}  ·  MIT")
        about.setObjectName("count")

        # about ARFEP IT-Service
        logo = QLabel()
        logo.setPixmap(svg_pixmap(brand.logo(theme.dark()), 30))
        logo.setCursor(Qt.CursorShape.PointingHandCursor)
        logo.mousePressEvent = lambda _e: self._open(brand.website(i18n.LANG))
        made_by = QLabel(tr("Glassbed is an open-source project by {company}.", company=brand.COMPANY))
        made_by.setWordWrap(True)
        tagline = QLabel(tr("IT service · Göttingen & nationwide"))
        tagline.setObjectName("hint")
        site_btn = QPushButton("arfep.de  ↗")
        site_btn.clicked.connect(lambda: self._open(brand.website(i18n.LANG)))
        help_btn = QPushButton(tr("Get IT help"))
        help_btn.clicked.connect(lambda: self._open(brand.contact(i18n.LANG)))
        about_text = QVBoxLayout()
        about_text.setSpacing(2)
        about_text.addWidget(made_by)
        about_text.addWidget(tagline)
        about_row = QHBoxLayout()
        about_row.setSpacing(16)
        about_row.addWidget(logo, 0, Qt.AlignmentFlag.AlignVCenter)
        about_row.addLayout(about_text, 1)
        links = QHBoxLayout()
        links.addWidget(site_btn)
        links.addWidget(help_btn)
        links.addStretch()
        divider = QWidget()
        divider.setObjectName("divider")
        divider.setFixedHeight(1)
        close = QPushButton(tr("Done"))
        close.setObjectName("primary")
        close.clicked.connect(self._done)
        cancel = QPushButton(tr("Cancel"))
        cancel.clicked.connect(self.closed.emit)
        title = QLabel(tr("Settings"))
        title.setObjectName("wordmark")

        card = QWidget()
        card.setObjectName("sidebar_r")
        card.setFixedWidth(500)
        lay = QVBoxLayout(card)
        lay.setContentsMargins(28, 24, 28, 22)
        lay.setSpacing(6)
        lay.addWidget(title)
        lay.addSpacing(16)
        for label, widget in ((tr("Language"), self.language), (tr("Appearance"), self.appearance),
                              (tr("Default save folder"), self.folder)):
            lay.addWidget(eyebrow(label))
            lay.addWidget(widget)
            lay.addSpacing(12)
        lay.addWidget(hint)
        lay.addSpacing(18)
        lay.addWidget(divider)
        lay.addSpacing(14)
        lay.addWidget(eyebrow(tr("About")))
        lay.addSpacing(4)
        lay.addLayout(about_row)
        lay.addSpacing(6)
        lay.addLayout(links)
        lay.addSpacing(20)
        bottom = QHBoxLayout()
        bottom.addWidget(about)
        bottom.addStretch()
        bottom.addWidget(cancel)
        bottom.addWidget(close)
        lay.addLayout(bottom)

        outer = QVBoxLayout(self)
        outer.addStretch(1)
        outer.addWidget(card, 0, Qt.AlignmentFlag.AlignHCenter)
        outer.addStretch(2)
        QShortcut(QKeySequence(Qt.Key.Key_Escape), self, self.closed.emit)

    @staticmethod
    def _open(url: str) -> None:
        QDesktopServices.openUrl(QUrl(url))

    def _done(self) -> None:
        self.applied.emit()
        self.closed.emit()

    def _choose_folder(self) -> None:
        start = self.folder.path() or Path.home() / "Documents"
        d = QFileDialog.getExistingDirectory(self, tr("Choose folder"), str(start))
        if d:
            self.folder.set_path(Path(d))

    # results
    def chosen_language(self) -> str:
        return self.language.currentData()

    def chosen_theme(self) -> str:
        return self.appearance.currentData()

    def chosen_folder(self) -> Path | None:
        return self.folder.path()
