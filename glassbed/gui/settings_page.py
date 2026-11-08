"""Settings page (inside the main window): language, appearance, folder, tray, autostart."""
from __future__ import annotations

from pathlib import Path

from PySide6.QtCore import QSettings, Qt, QUrl, Signal
from PySide6.QtGui import QDesktopServices, QKeySequence, QShortcut
from PySide6.QtWidgets import (QCheckBox, QFileDialog, QHBoxLayout, QLabel, QPushButton,
                               QScrollArea, QVBoxLayout, QWidget)

from .. import __version__, autostart, brand, i18n
from ..i18n import tr
from . import theme
from .tray import available as tray_available
from .widgets import FolderPicker, Segmented, eyebrow, svg_pixmap

THEMES = [("system", "System"), ("light", "Light"), ("dark", "Dark")]
CARD_WIDTH, CARD_MARGIN = 500, 28


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

        # notification area (tray) and start with Windows – both off unless chosen
        self.tray = QCheckBox(tr("Show icon in the notification area"))
        self.tray.setChecked(settings.value("ui/tray", False, type=bool))
        self.autostart = QCheckBox(tr("Start with Windows"))
        self.autostart.setChecked(settings.value("ui/autostart", False, type=bool))
        self.autostart.setVisible(autostart.supported())
        tray_hint = QLabel(tr("With the icon, closing the window keeps Glassbed running in the notification "
                              "area; it can scan from there and warns when toner runs low."))
        tray_hint.setObjectName("hint")
        tray_hint.setWordWrap(True)
        if not tray_available():
            self.tray.setChecked(False)
            self.tray.setEnabled(False)
            tray_hint.setText(tr("This system has no notification area."))
        self.tray.toggled.connect(self._tray_toggled)
        self._tray_toggled(self.tray.isChecked())
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
        about_text.setSpacing(4)
        about_text.addWidget(made_by)
        about_text.addWidget(tagline)
        about_row = QHBoxLayout()
        about_row.setSpacing(16)
        about_row.addWidget(logo, 0, Qt.AlignmentFlag.AlignVCenter)
        about_row.addLayout(about_text, 1)
        # wrapped labels in a nested row don't report their height: reserve it explicitly
        text_width = CARD_WIDTH - 2 * CARD_MARGIN - logo.sizeHint().width() - about_row.spacing()
        made_by.ensurePolished()                # measure with the stylesheet's font
        made_by.setMinimumHeight(made_by.heightForWidth(text_width) + 2)
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
        close.ensurePolished()                  # size with the stylesheet's padding, not before it
        close.setMinimumHeight(close.sizeHint().height())
        cancel = QPushButton(tr("Cancel"))
        cancel.clicked.connect(self.closed.emit)
        title = QLabel(tr("Settings"))
        title.setObjectName("wordmark")

        card = QWidget()
        card.setObjectName("sidebar_r")
        card.setFixedWidth(CARD_WIDTH)
        lay = QVBoxLayout(card)
        lay.setContentsMargins(CARD_MARGIN, 24, CARD_MARGIN, 22)
        lay.setSpacing(6)
        lay.addWidget(title)
        lay.addSpacing(16)
        for label, widget in ((tr("Language"), self.language), (tr("Appearance"), self.appearance),
                              (tr("Default save folder"), self.folder)):
            lay.addWidget(eyebrow(label))
            lay.addWidget(widget)
            lay.addSpacing(12)
        lay.addWidget(hint)
        lay.addSpacing(12)
        lay.addWidget(eyebrow(tr("Notification area")))
        lay.addWidget(self.tray)
        lay.addWidget(self.autostart)
        lay.addWidget(tray_hint)
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

        # scrolls instead of squeezing the card when the window is low
        holder = QWidget()
        holder.setObjectName("settingsholder")
        inner = QVBoxLayout(holder)
        inner.addStretch(1)
        inner.addWidget(card, 0, Qt.AlignmentFlag.AlignHCenter)
        inner.addStretch(2)
        scroll = QScrollArea()
        scroll.setWidget(holder)
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QScrollArea.Shape.NoFrame)
        scroll.setStyleSheet("QScrollArea, QWidget#settingsholder { background: transparent; }")
        outer = QVBoxLayout(self)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.addWidget(scroll)
        QShortcut(QKeySequence(Qt.Key.Key_Escape), self, self.closed.emit)

    @staticmethod
    def _open(url: str) -> None:
        QDesktopServices.openUrl(QUrl(url))

    def _tray_toggled(self, on: bool) -> None:
        """Starting with Windows needs the tray icon: without it the app would start invisible."""
        self.autostart.setEnabled(on)
        if not on:
            self.autostart.setChecked(False)

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

    def chosen_tray(self) -> bool:
        return self.tray.isChecked()

    def chosen_autostart(self) -> bool:
        return self.autostart.isChecked()
