"""Scan tab: input (left) → pages on the platen (centre) → output (right)."""
from __future__ import annotations

import threading
from datetime import datetime
from itertools import count
from pathlib import Path
from typing import Callable

from PIL import Image
from PySide6.QtCore import QSettings, Qt, QTimer, Signal
from PySide6.QtGui import QKeySequence, QShortcut
from PySide6.QtWidgets import (QCheckBox, QComboBox, QFileDialog, QHBoxLayout, QLabel,
                               QListWidgetItem, QPushButton, QToolButton,
                               QVBoxLayout, QWidget)

from ..discovery import Device
from ..escl import (EsclScanner, FeederEmpty, ScanCancelled, ScannerBusy, ScannerCaps,
                    ScanSettings)
from .. import i18n
from .. import edit
from ..edit import Edits
from ..i18n import tr
from ..printing import print_pages
from ..render import PageRef, estimate_size, planned_paths, save_pages
from .widgets import (FileNameEdit, FolderPicker, PageGrid, Segmented, Stepper, ZoomControl,
                      eyebrow, thumb_pixmap)
from .editor import PageEditor
from .files import reveal
from .worker import run_task

COLOR_MODES = [("RGB24", "Color"), ("Grayscale8", "Gray"), ("BlackAndWhite1", "B/W")]
PAPERS = [("A4", "A4"), ("Letter", "Letter"), ("A5", "A5"), ("Max", "Full area")]
INTENTS = [("Document", "Document"), ("Photo", "Photo")]
FORMATS = [("pdf", "PDF"), ("jpg", "JPG"), ("png", "PNG")]
QUALITIES = [("high", "High"), ("normal", "Normal"), ("compact", "Compact")]
SPLITS = [(0, "One file"), (1, "Per page"), (-1, "Every N")]
MEDIA_FOR_PAPER = {"A4": "iso_a4_210x297mm", "Letter": "na_letter_8.5x11in",
                   "A5": "iso_a4_210x297mm", "Max": "iso_a4_210x297mm"}


def _combo(items: list[tuple[str, str]]) -> QComboBox:
    box = QComboBox()
    for key, label in items:
        box.addItem(tr(label), key)
    return box


def _segmented(items) -> Segmented:
    return Segmented([(tr(label), key) for key, label in items])


def _select(box, key) -> None:
    i = box.findData(key)
    if i >= 0:
        box.setCurrentIndex(i)


def human_size(n: int) -> str:
    if n < 1024 * 1024:
        return f"{max(1, round(n / 1024))} KB"
    text = f"{n / 1024 / 1024:.1f} MB"
    return text.replace(".", ",") if i18n.LANG in ("de", "tr") else text


def _sidebar(layout: QVBoxLayout, name: str) -> QWidget:
    w = QWidget()
    w.setObjectName(name)
    w.setLayout(layout)
    w.setFixedWidth(272)
    return w


class ScanTab(QWidget):
    message = Signal(str)
    toast = Signal(str, str, object)        # title, detail, saved path (or None)
    alert = Signal(str, str, str)           # kind (info/error), title, body
    ask = Signal(str, str, str, object)     # title, body, button label, callback
    open_page = Signal(object)              # a view to show inside the main window

    def __init__(self, device: Callable[[], Device | None], settings: QSettings,
                 parent: QWidget | None = None):
        super().__init__(parent)
        self._device = device
        self._settings = settings
        self._pages: dict[int, tuple[Image.Image, int]] = {}      # edited result, dpi
        self._sources: dict[int, tuple[Image.Image, Edits]] = {}  # original scan, edits
        self._ids = count(1)
        self._cancel: threading.Event | None = None
        self._caps: ScannerCaps | None = None
        self._scanned = 0
        self._size_cache: dict[tuple, int] = {}
        self._dirty = False                  # pages/output changed since the last save
        self._last_saved: list[Path] = []
        self._estimate_timer = QTimer(self, singleShot=True, interval=250)
        self._estimate_timer.timeout.connect(self._update_estimate)
        self._build()
        self._load_settings()
        self._update_state()

    # -- layout -------------------------------------------------------------
    def _build(self) -> None:
        # left: input – scan options, start button at the bottom like the key on the device
        self.source = _segmented([("Platen", "Glass"), ("Feeder", "Feeder")])
        self.mode = _segmented(COLOR_MODES)
        self.resolution = QComboBox()
        for dpi in (100, 200, 300):
            self.resolution.addItem(f"{dpi} dpi", dpi)
        self.paper = _combo(PAPERS)
        self.intent = _segmented(INTENTS)
        self.source.currentIndexChanged.connect(lambda _: self.apply_capabilities(self._caps))

        self.scan_btn = QPushButton(tr("Scan"))
        self.scan_btn.setObjectName("primary")
        self.scan_btn.setCursor(Qt.CursorShape.PointingHandCursor)
        self.scan_btn.clicked.connect(self.start_scan)
        self.cancel_btn = QPushButton(tr("Cancel"))
        self.cancel_btn.setObjectName("danger")
        self.cancel_btn.clicked.connect(self.cancel_scan)
        self.cancel_btn.hide()
        hint = QLabel(tr("Next scan is added to the current pages."))
        hint.setObjectName("hint")
        hint.setWordWrap(True)

        left = QVBoxLayout()
        left.setContentsMargins(20, 22, 20, 20)
        left.setSpacing(6)
        for label, widget in ((tr("Source"), self.source), (tr("Mode"), self.mode),
                              (tr("Resolution"), self.resolution), (tr("Paper"), self.paper),
                              (tr("Content"), self.intent)):
            left.addWidget(eyebrow(label))
            left.addWidget(widget)
            left.addSpacing(10)
        left.addStretch()
        left.addWidget(hint)
        left.addSpacing(6)
        left.addWidget(self.cancel_btn)
        left.addWidget(self.scan_btn)

        # centre: the platen with the scanned pages
        self.grid = PageGrid(tr("Place a document on the glass or in the feeder\nand click “Scan”."))
        self.grid.itemDoubleClicked.connect(self._edit_item)
        self.grid.model().rowsMoved.connect(lambda *_: (self.grid.renumber(), self._mark_dirty()))
        self.grid.itemSelectionChanged.connect(self._update_state)

        def tool(text, slot):
            b = QToolButton()
            b.setText(text)
            b.setCursor(Qt.CursorShape.PointingHandCursor)
            b.clicked.connect(slot)
            return b

        self.edit_btn = tool("✎  " + tr("Edit"), self._edit_selected)
        self.edit_btn.setToolTip(tr("Crop, straighten, brightness …"))
        self.rot_l = tool("↺", lambda: self._rotate(90))
        self.rot_l.setToolTip(tr("Rotate left"))
        self.rot_r = tool("↻", lambda: self._rotate(-90))
        self.rot_r.setToolTip(tr("Rotate right"))
        for b in (self.rot_l, self.rot_r):
            b.setObjectName("icon")
        self.del_btn = tool(tr("Delete"), self._delete_selected)
        self.clear_btn = tool(tr("Clear all"), self.clear_pages)
        self.count_lbl = QLabel()
        self.count_lbl.setObjectName("count")
        bar = QHBoxLayout()
        bar.setContentsMargins(14, 10, 20, 0)
        for w in (self.edit_btn, self.rot_l, self.rot_r, self.del_btn, self.clear_btn):
            bar.addWidget(w)
        bar.addStretch()
        bar.addWidget(self.count_lbl)
        bar.addSpacing(14)
        bar.addWidget(ZoomControl(self.grid, self._settings, "ui/zoom_scan"))
        centre = QVBoxLayout()
        centre.setContentsMargins(0, 0, 0, 0)
        centre.setSpacing(0)
        centre.addLayout(bar)
        centre.addWidget(self.grid, 1)

        # right: output – where and how the pages are saved
        self.filename = FileNameEdit()
        self.folder = FolderPicker(tr("Choose folder…"))
        self.folder.clicked.connect(self._choose_folder)
        self.format = _segmented(FORMATS)
        self.quality = _segmented(QUALITIES)
        self.estimate_lbl = QLabel()
        self.estimate_lbl.setObjectName("count")
        self.split = _segmented(SPLITS)
        self.split_n = Stepper(2, 99, 2)
        self.split_n_lbl = QLabel(tr("pages per file"))
        self.split_n_lbl.setObjectName("hint")
        split_n_row = QHBoxLayout()
        split_n_row.addWidget(self.split_n, 1)
        split_n_row.addWidget(self.split_n_lbl, 1)
        self.split_n_box = QWidget()
        self.split_n_box.setLayout(split_n_row)
        split_n_row.setContentsMargins(0, 4, 0, 0)
        self.clear_after = QCheckBox(tr("Clear pages after saving"))
        self.open_after = QCheckBox(tr("Open folder after saving"))
        for w in (self.format, self.quality, self.split):
            w.currentIndexChanged.connect(lambda _: self._mark_dirty())
        self.split_n.valueChanged.connect(lambda _: self._mark_dirty())
        self.filename.textChanged.connect(self._mark_dirty)

        self.copies = Stepper(1, 99, 1)
        self.copies.setToolTip(tr("Copies"))
        self.print_btn = QPushButton(tr("Print"))
        self.print_btn.setToolTip(tr("Print copy"))
        self.print_btn.setMinimumHeight(34)
        self.copies.setMinimumHeight(34)
        self.print_btn.clicked.connect(self.print_copy)
        self.save_btn = QPushButton(tr("Save"))
        self.save_btn.setObjectName("primary")
        self.save_btn.setCursor(Qt.CursorShape.PointingHandCursor)
        self.save_btn.clicked.connect(self.save)

        right = QVBoxLayout()
        right.setContentsMargins(20, 22, 20, 20)
        right.setSpacing(6)
        right.addWidget(eyebrow(tr("File name")))
        right.addWidget(self.filename)
        right.addSpacing(10)
        right.addWidget(eyebrow(tr("Folder")))
        right.addWidget(self.folder)
        right.addSpacing(10)
        right.addWidget(eyebrow(tr("Format")))
        right.addWidget(self.format)
        right.addSpacing(10)
        q_head = QHBoxLayout()
        q_head.addWidget(eyebrow(tr("Quality")))
        q_head.addStretch()
        q_head.addWidget(self.estimate_lbl)
        right.addLayout(q_head)
        right.addWidget(self.quality)
        right.addSpacing(10)
        self.split_head = eyebrow(tr("Files"))
        right.addWidget(self.split_head)
        right.addWidget(self.split)
        right.addWidget(self.split_n_box)
        right.addSpacing(10)
        right.addWidget(self.clear_after)
        right.addWidget(self.open_after)
        right.addStretch()
        right.addWidget(eyebrow(tr("Copy")))
        copy_row = QHBoxLayout()
        copy_row.addWidget(self.copies, 1)
        copy_row.addWidget(self.print_btn, 1)
        right.addLayout(copy_row)
        right.addSpacing(12)
        right.addWidget(self.save_btn)

        root = QHBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)
        root.addWidget(_sidebar(left, "sidebar"))
        root.addLayout(centre, 1)
        root.addWidget(_sidebar(right, "sidebar_r"))

        QShortcut(QKeySequence.StandardKey.Delete, self.grid, self._delete_selected)
        QShortcut(QKeySequence("Ctrl+S"), self, self.save)

    # -- settings -----------------------------------------------------------
    def _load_settings(self) -> None:
        s = self._settings
        _select(self.source, s.value("scan/source", "Platen"))
        _select(self.mode, s.value("scan/mode", "RGB24"))
        _select(self.resolution, int(s.value("scan/resolution", 300)))
        _select(self.paper, s.value("scan/paper", "A4"))
        _select(self.intent, s.value("scan/intent", "Document"))
        _select(self.format, str(s.value("scan/format", "pdf")).lower())
        _select(self.quality, s.value("scan/quality", "normal"))
        _select(self.split, int(s.value("scan/split", 0)))
        self.split_n.setValue(int(s.value("scan/split_n", 2)))
        folder = s.value("scan/folder", "")
        self.folder.set_path(Path(folder) if folder else None)
        self.clear_after.setChecked(s.value("scan/clear_after", True, type=bool))
        self.open_after.setChecked(s.value("scan/open_after", False, type=bool))
        self._new_filename()

    def save_settings(self) -> None:
        s = self._settings
        s.setValue("scan/source", self.source.currentData())
        s.setValue("scan/mode", self.mode.currentData())
        s.setValue("scan/resolution", self.resolution.currentData())
        s.setValue("scan/paper", self.paper.currentData())
        s.setValue("scan/intent", self.intent.currentData())
        s.setValue("scan/format", self.format.currentData())
        s.setValue("scan/quality", self.quality.currentData())
        s.setValue("scan/split", self.split.currentData())
        s.setValue("scan/split_n", self.split_n.value())
        if self.folder.path():
            s.setValue("scan/folder", str(self.folder.path()))
        s.setValue("scan/clear_after", self.clear_after.isChecked())
        s.setValue("scan/open_after", self.open_after.isChecked())

    def set_default_folder(self, folder: Path | None) -> None:
        self.folder.set_path(folder)

    def _choose_folder(self) -> bool:
        start = self.folder.path() or Path.home() / "Documents"
        d = QFileDialog.getExistingDirectory(self, tr("Choose folder"), str(start))
        if not d:
            return False
        self.folder.set_path(Path(d))
        self._settings.setValue("scan/folder", d)
        self._mark_dirty()
        return True

    def _mark_dirty(self) -> None:
        self._dirty = True
        self._update_state()

    def _new_filename(self) -> None:
        self.filename.setText(datetime.now().strftime("Scan_%Y-%m-%d_%H-%M-%S"))

    def apply_capabilities(self, caps: ScannerCaps | None) -> None:
        """Enable only what the connected scanner supports."""
        self._caps = caps
        if not caps:
            return
        self.source.blockSignals(True)
        for i in range(self.source.count()):
            self.source.setItemEnabled(i, self.source.itemData(i) in caps.sources)
        if self.source.currentData() not in caps.sources and caps.sources:
            _select(self.source, next(iter(caps.sources)))
        self.source.blockSignals(False)
        src = caps.sources.get(self.source.currentData())
        if src:
            current = self.resolution.currentData()
            self.resolution.clear()
            for dpi in src.resolutions:
                self.resolution.addItem(f"{dpi} dpi", dpi)
            _select(self.resolution, current if current in src.resolutions else max(src.resolutions))

    # -- scanning -----------------------------------------------------------
    def start_scan(self) -> None:
        device = self._device()
        if not device:
            self.message.emit(tr("No printer selected."))
            return
        settings = ScanSettings(
            source=self.source.currentData(),
            color_mode=self.mode.currentData(),
            resolution=self.resolution.currentData(),
            paper=self.paper.currentData(),
            intent=self.intent.currentData(),
        )
        self._cancel = threading.Event()
        self._scanned = 0
        self._set_scanning(True)
        self.message.emit(tr("Scanning…"))

        def job(progress, url, st, cancel):
            return len(EsclScanner(url).scan(st, on_page=progress, cancel=cancel))

        run_task(job, device.escl_url, settings, self._cancel,
                 on_progress=lambda img: self._add_page(img, settings.resolution),
                 on_done=lambda n: self._scan_finished(None),
                 on_error=self._scan_finished)

    def cancel_scan(self) -> None:
        if self._cancel:
            self._cancel.set()

    def _set_scanning(self, busy: bool) -> None:
        self.scan_btn.setEnabled(not busy)
        self.scan_btn.setText(tr("Scanning…") if busy else tr("Scan"))
        self.cancel_btn.setVisible(busy)
        for w in (self.source, self.mode, self.resolution, self.paper, self.intent):
            w.setEnabled(not busy)

    def _scan_finished(self, error: BaseException | None) -> None:
        self._set_scanning(False)
        self._cancel = None
        if error is None:
            self.message.emit(tr("{n} page(s) scanned.", n=self._scanned))
        elif isinstance(error, ScanCancelled):
            self.message.emit(tr("Scan cancelled."))
        elif isinstance(error, FeederEmpty):
            self.alert.emit("info", tr("Scan"), tr("The document feeder is empty. Insert pages or use the glass."))
        elif isinstance(error, ScannerBusy):
            self.alert.emit("info", tr("Scan"), tr("The scanner is busy. Try again in a moment."))
        else:
            self.alert.emit("error", tr("Scan failed"), str(error))
        self._update_state()

    def _add_page(self, img: Image.Image, dpi: int) -> None:
        if not self._pages:
            self._new_filename()
            self._last_saved = []
        pid = next(self._ids)
        self._pages[pid] = (img, dpi)
        self._sources[pid] = (img, Edits())
        item = QListWidgetItem(thumb_pixmap(img), "")
        item.setData(Qt.ItemDataRole.UserRole, pid)
        self.grid.addItem(item)
        self.grid.renumber()
        self.grid.scrollToItem(item)
        self._scanned += 1
        self.message.emit(tr("{n} page(s) scanned.", n=self._scanned))
        self._mark_dirty()

    # -- page operations ----------------------------------------------------
    def _ordered_ids(self) -> list[int]:
        return [it.data(Qt.ItemDataRole.UserRole) for it in self.grid.ordered_items()]

    def _ordered(self) -> list[tuple[Image.Image, int]]:
        return [self._pages[pid] for pid in self._ordered_ids()]

    def _set_edits(self, item: QListWidgetItem, edits: Edits) -> None:
        pid = item.data(Qt.ItemDataRole.UserRole)
        original, _old = self._sources[pid]
        self._sources[pid] = (original, edits)
        img = edit.apply(original, edits)
        self._pages[pid] = (img, self._pages[pid][1])
        item.setIcon(thumb_pixmap(img))
        item.setToolTip(tr("Edited") if not edits.is_identity else "")
        self._size_cache.clear()

    def _rotate(self, angle: int) -> None:
        for item in self.grid.selectedItems() or self.grid.ordered_items():
            pid = item.data(Qt.ItemDataRole.UserRole)
            self._set_edits(item, self._sources[pid][1].rotated(angle))
        self._mark_dirty()

    def _edit_selected(self) -> None:
        items = self.grid.selectedItems()
        if self.grid.count():
            self._edit_item(items[0] if items else self.grid.item(0))

    def _edit_item(self, item: QListWidgetItem) -> None:
        items = self.grid.ordered_items()
        ids = [it.data(Qt.ItemDataRole.UserRole) for it in items]
        editor = PageEditor([self._sources[i][0] for i in ids], [self._sources[i][1] for i in ids],
                            start=items.index(item))

        def applied(edits):
            changed = False
            for it, pid, new in zip(items, ids, edits):
                if pid in self._sources and new != self._sources[pid][1]:
                    self._set_edits(it, new)
                    changed = True
            if changed:
                self._mark_dirty()

        editor.applied.connect(applied)
        self.open_page.emit(editor)

    def _delete_selected(self) -> None:
        for item in self.grid.selectedItems():
            self._pages.pop(item.data(Qt.ItemDataRole.UserRole), None)
            self._sources.pop(item.data(Qt.ItemDataRole.UserRole), None)
            self.grid.takeItem(self.grid.row(item))
        self.grid.renumber()
        self._mark_dirty()

    def clear_pages(self) -> None:
        self.grid.clear()
        self._pages.clear()
        self._sources.clear()
        self._dirty = False
        self._update_state()

    def _split_value(self) -> int:
        v = self.split.currentData()
        return self.split_n.value() if v == -1 else v

    def _update_state(self) -> None:
        n = self.grid.count()
        self.grid.viewport().update()
        self.count_lbl.setText(tr("{n} page(s)", n=n) if n else "")
        for w in (self.print_btn, self.clear_btn, self.rot_l, self.rot_r, self.edit_btn):
            w.setEnabled(n > 0)
        saved = n > 0 and not self._dirty and bool(self._last_saved)
        if self.save_btn.text() != tr("Saving…"):
            self.save_btn.setText("✓  " + tr("Saved") if saved else tr("Save"))
            self.save_btn.setEnabled(n > 0 and not saved)
            self.save_btn.setToolTip(str(self._last_saved[0]) if saved else "")
        self.del_btn.setEnabled(bool(self.grid.selectedItems()))
        is_pdf = self.format.currentData() == "pdf"
        for w in (self.split_head, self.split):
            w.setVisible(is_pdf)
        self.split_n_box.setVisible(is_pdf and self.split.currentData() == -1)
        self._estimate_timer.start()

    def _update_estimate(self) -> None:
        pages = self._ordered()
        if not pages:
            self.estimate_lbl.setText("")
            return
        fmt, quality = self.format.currentData(), self.quality.currentData()
        ids = tuple(self._ordered_ids()[:2])
        key = (ids, fmt, quality)
        if key not in self._size_cache:
            per = estimate_size(pages[:2], fmt, quality)
            self._size_cache[key] = per / len(pages[:2])
        total = int(self._size_cache[key] * len(pages))
        self.estimate_lbl.setText("≈ " + human_size(total))

    # -- output -------------------------------------------------------------
    def has_unsaved(self) -> bool:
        """Pages that would be lost on exit (or a scan still running)."""
        if self._cancel is not None:
            return True
        return self.grid.count() > 0 and (self._dirty or not self._last_saved)

    def save(self, then=None) -> None:
        """Save the pages; ``then()`` runs only after a successful save."""
        pages = self._ordered()
        if not pages:
            return
        if not self._dirty and self._last_saved:
            self.toast.emit(tr("Already saved"), self._last_saved[0].name, self._last_saved[0])
            return
        folder = self.folder.path()
        if folder is None or not folder.is_dir():
            # never save "somewhere": ask until there is a real folder
            if not self._choose_folder():
                return
            folder = self.folder.path()
        fmt = self.format.currentData()
        split = self._split_value() if fmt == "pdf" else 0
        name = self.filename.text() or datetime.now().strftime("Scan_%Y-%m-%d_%H-%M-%S")
        stem, n = name, 2
        while any(p.exists() for p in planned_paths(folder / f"{stem}.{fmt}", fmt, len(pages), split)):
            stem = f"{name} ({n})"
            n += 1
        self.save_btn.setEnabled(False)
        self.save_btn.setText(tr("Saving…"))
        quality = self.quality.currentData()

        def job(_progress):
            return save_pages(pages, folder / f"{stem}.{fmt}", fmt, quality, split)

        def done(written):
            self.save_btn.setText(tr("Save"))
            self._dirty = False
            self._last_saved = written
            self.save_settings()
            size = sum(p.stat().st_size for p in written)
            if len(written) == 1:
                detail = f"{written[0].name}  ·  {human_size(size)}"
            else:
                detail = tr("{n} files", n=len(written)) + f"  ·  {human_size(size)}"
            self.toast.emit(tr("Saved"), detail, written[0])
            self.message.emit(tr("Saved: {path}", path=written[0]))
            if self.open_after.isChecked():
                reveal(written[0])
            if self.clear_after.isChecked():
                self.clear_pages()
            self._update_state()
            if then:
                then()

        def failed(e):
            self.save_btn.setText(tr("Save"))
            self._mark_dirty()
            self.alert.emit("error", tr("Could not save"), str(e))

        run_task(job, on_done=done, on_error=failed)

    def print_copy(self) -> None:
        device = self._device()
        pages = self._ordered()
        if not device or not pages:
            return
        refs = [PageRef(image=im, dpi=d) for im, d in pages]
        color = self.mode.currentData() == "RGB24"
        media = MEDIA_FOR_PAPER.get(self.paper.currentData(), "iso_a4_210x297mm")
        copies, name = self.copies.value(), self.filename.text() or "Scan"
        self.print_btn.setEnabled(False)
        self.message.emit(tr("Printing…"))

        def job(progress, uri):
            print_pages(uri, refs, media=media, color=color, copies=copies, job_name=name,
                        progress=lambda i, n: progress((i, n)))

        def done(error=None):
            self.print_btn.setEnabled(True)
            if error:
                self.alert.emit("error", tr("Print failed"), str(error))
            else:
                self.toast.emit(tr("Sent to printer."),
                                tr("{n} page(s)", n=len(refs)) + f"  ×  {copies}", None)

        run_task(job, device.ipp_uri,
                 on_progress=lambda p: self.message.emit(tr("Preparing page {i} of {n}…", i=p[0], n=p[1])),
                 on_done=lambda _: done(), on_error=done)
