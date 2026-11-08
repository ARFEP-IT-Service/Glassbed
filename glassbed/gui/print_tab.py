"""Print tab: drop PDFs/images, pick options, print."""
from __future__ import annotations

from pathlib import Path
from typing import Callable

from PIL import Image
from PySide6.QtCore import QSettings, Qt, Signal
from PySide6.QtWidgets import (QCheckBox, QComboBox, QFileDialog, QHBoxLayout, QLabel,
                               QLineEdit, QListWidget, QListWidgetItem,
                               QProgressBar, QPushButton, QToolButton, QVBoxLayout,
                               QWidget)

from ..discovery import Device
from ..i18n import tr
from ..printing import print_pages
from ..render import (SUPPORTED_EXTENSIONS, PageRef, open_document, parse_page_range,
                      render_for_print, thumbnail)
from .widgets import (THUMB_SOURCE, PageGrid, PreviewPage, Segmented, Stepper, ZoomControl,
                      eyebrow, pil_to_pixmap)
from .worker import run_task

MEDIA_LABELS = {
    "iso_a4_210x297mm": "A4",
    "na_letter_8.5x11in": "Letter",
    "na_legal_8.5x14in": "Legal",
    "iso_a5_148x210mm": "A5",
}


class PrintTab(QWidget):
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
        self._files: list[tuple[Path, list[PageRef]]] = []
        self._thumb_generation = 0
        self.setAcceptDrops(True)
        self._build()
        self._load_settings()
        self._update_state()

    # -- layout -------------------------------------------------------------
    def _build(self) -> None:
        # sidebar: print options, print button at the bottom
        self.copies = Stepper(1, 99, 1)
        self.color = Segmented([(tr("Color"), True), (tr("B/W"), False)])
        self.media = QComboBox()
        for key, label in MEDIA_LABELS.items():
            self.media.addItem(label, key)
        self.pages = QLineEdit()
        self.pages.setPlaceholderText(tr("All") + " – " + tr("e.g. 1-3, 5"))
        self.duplex = QCheckBox(tr("Manual duplex"))
        self.duplex.setToolTip(tr("Print both sides by reinserting the stack"))

        self.print_btn = QPushButton(tr("Print"))
        self.print_btn.setObjectName("primary")
        self.print_btn.setCursor(Qt.CursorShape.PointingHandCursor)
        self.print_btn.clicked.connect(self.start_print)
        self.progress = QProgressBar()
        self.progress.setTextVisible(False)
        self.progress.hide()

        side = QVBoxLayout()
        side.setContentsMargins(20, 22, 20, 20)
        side.setSpacing(6)
        for label, widget in ((tr("Copies"), self.copies), (tr("Color mode"), self.color),
                              (tr("Paper"), self.media), (tr("Pages"), self.pages)):
            side.addWidget(eyebrow(label))
            side.addWidget(widget)
            side.addSpacing(10)
        side.addWidget(self.duplex)
        side.addStretch()
        side.addWidget(self.progress)
        side.addSpacing(6)
        side.addWidget(self.print_btn)
        sidebar = QWidget()
        sidebar.setObjectName("sidebar")
        sidebar.setLayout(side)
        sidebar.setFixedWidth(272)

        # work area: files + pages on the platen
        def tool(text, slot):
            b = QToolButton()
            b.setText(text)
            b.setCursor(Qt.CursorShape.PointingHandCursor)
            b.clicked.connect(slot)
            return b

        add = tool("＋  " + tr("Add files…"), self._choose_files)
        self.remove_btn = tool(tr("Remove"), self._remove_selected)
        self.clear_btn = tool(tr("Clear all"), self.clear)
        self.page_count = QLabel()
        self.page_count.setObjectName("count")
        bar = QHBoxLayout()
        bar.setContentsMargins(14, 10, 20, 0)
        bar.addWidget(add)
        bar.addWidget(self.remove_btn)
        bar.addWidget(self.clear_btn)
        bar.addStretch()
        bar.addWidget(self.page_count)
        self._zoom_bar = bar

        self.files = QListWidget()
        self.files.setObjectName("files")
        self.files.itemSelectionChanged.connect(self._update_state)
        files_row = QHBoxLayout()
        files_row.setContentsMargins(20, 8, 20, 0)
        files_row.addWidget(self.files)

        self.grid = PageGrid(tr("Drop PDFs or images here\nor click “Add files…”."), reorderable=False)
        self.grid.itemDoubleClicked.connect(self._preview)
        self._zoom_bar.addSpacing(14)
        self._zoom_bar.addWidget(ZoomControl(self.grid, self._settings, "ui/zoom_print"))

        work = QVBoxLayout()
        work.setContentsMargins(0, 0, 0, 0)
        work.setSpacing(0)
        work.addLayout(bar)
        work.addLayout(files_row)
        work.addWidget(self.grid, 1)

        root = QHBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)
        root.addWidget(sidebar)
        root.addLayout(work, 1)

    def _load_settings(self) -> None:
        s = self._settings
        i = self.color.findData(s.value("print/color", True, type=bool))
        self.color.setCurrentIndex(max(0, i))
        i = self.media.findData(s.value("print/media", "iso_a4_210x297mm"))
        self.media.setCurrentIndex(max(0, i))

    def save_settings(self) -> None:
        self._settings.setValue("print/color", self.color.currentData())
        self._settings.setValue("print/media", self.media.currentData())

    # -- files --------------------------------------------------------------
    def dragEnterEvent(self, e) -> None:
        if e.mimeData().hasUrls():
            e.acceptProposedAction()

    def dropEvent(self, e) -> None:
        self.add_files([u.toLocalFile() for u in e.mimeData().urls() if u.isLocalFile()])

    def _choose_files(self) -> None:
        patterns = " ".join(f"*{ext}" for ext in sorted(SUPPORTED_EXTENSIONS))
        paths, _ = QFileDialog.getOpenFileNames(
            self, tr("Add files…"), self._settings.value("print/folder", str(Path.home())),
            f"{tr('Supported files')} ({patterns})")
        if paths:
            self._settings.setValue("print/folder", str(Path(paths[0]).parent))
            self.add_files(paths)

    def add_files(self, paths) -> None:
        for p in paths:
            path = Path(p)
            if path.suffix.lower() not in SUPPORTED_EXTENSIONS:
                continue
            try:
                refs = open_document(path)
            except Exception as e:  # noqa: BLE001
                self.alert.emit("error", tr("Could not open file"), f"{path.name}: {e}")
                continue
            self._files.append((path, refs))
            self.files.addItem(QListWidgetItem(f"{path.name}   ·   {tr('{n} page(s)', n=len(refs))}"))
        self._rebuild_pages()

    def _remove_selected(self) -> None:
        rows = sorted((self.files.row(i) for i in self.files.selectedItems()), reverse=True)
        for r in rows:
            self.files.takeItem(r)
            del self._files[r]
        self._rebuild_pages()

    def clear(self) -> None:
        self.files.clear()
        self._files.clear()
        self._rebuild_pages()

    def all_pages(self) -> list[PageRef]:
        return [ref for _, refs in self._files for ref in refs]

    def _rebuild_pages(self) -> None:
        self.grid.clear()
        refs = self.all_pages()
        placeholder = Image.new("RGB", (254, 360), "white")
        for i, ref in enumerate(refs, 1):
            item = QListWidgetItem(pil_to_pixmap(placeholder), f"{i:02d}")
            item.setTextAlignment(Qt.AlignmentFlag.AlignHCenter)
            self.grid.addItem(item)
        self._update_state()
        if not refs:
            return
        self._thumb_generation += 1
        gen = self._thumb_generation
        self.message.emit(tr("Loading pages…"))

        def job(progress, refs):
            for i, ref in enumerate(refs):
                progress((gen, i, thumbnail(ref, THUMB_SOURCE)))

        def show(p):
            g, i, img = p
            if g == self._thumb_generation and i < self.grid.count():
                self.grid.item(i).setIcon(pil_to_pixmap(img))

        run_task(job, refs, on_progress=show,
                 on_done=lambda _: self.message.emit(tr("Ready")),
                 on_error=lambda e: self.message.emit(str(e)))

    def _preview(self, item: QListWidgetItem) -> None:
        ref = self.all_pages()[self.grid.row(item)]
        img = render_for_print(ref, self.media.currentData(), self.color.currentData(), dpi=100)
        self.open_page.emit(PreviewPage(img, ref.label, tr("Back")))

    def _update_state(self) -> None:
        n = self.grid.count()
        self.files.setVisible(bool(self._files))
        self.files.setFixedHeight(min(96, 12 + 30 * max(1, self.files.count())))   # grows with the list
        self.grid.viewport().update()
        self.page_count.setText(tr("{n} page(s)", n=n) if n else "")
        self.print_btn.setEnabled(n > 0)
        self.clear_btn.setEnabled(bool(self._files))
        self.remove_btn.setEnabled(bool(self.files.selectedItems()))

    # -- printing -----------------------------------------------------------
    def start_print(self) -> None:
        device = self._device()
        if not device:
            self.message.emit(tr("No printer selected."))
            return
        refs = self.all_pages()
        try:
            selected = [refs[i] for i in parse_page_range(self.pages.text(), len(refs))]
        except ValueError:
            self.alert.emit("error", tr("Print"), tr("Invalid page range."))
            return
        if not selected:
            self.alert.emit("info", tr("Print"), tr("Nothing to print."))
            return
        self.save_settings()
        opts = dict(media=self.media.currentData(), color=self.color.currentData(),
                    copies=self.copies.value(),
                    job_name=self._files[0][0].name if len(self._files) == 1 else "Glassbed")

        if self.duplex.isChecked() and len(selected) > 1:
            fronts = selected[0::2]
            backs = selected[1::2]
            if len(backs) < len(fronts):     # last sheet has no back side
                blank = Image.new("RGB", (10, 10), "white")
                backs.append(PageRef(image=blank))
            backs.reverse()
            opts["copies"] = 1

            def after_fronts():
                self.ask.emit(tr("Second side"), tr(
                    "The front sides are printing.\n\nWhen they are done, take the stack from the output tray and put it back into the paper tray so the blank sides get printed (usually: do not flip it, just move it).\n\nTip: try it once with 4 pages.\n\nContinue with the back sides?"),
                    tr("Print back sides"), lambda: self._send(device, backs, opts))

            self._send(device, fronts, opts, then=after_fronts)
        else:
            self._send(device, selected, opts)

    def _send(self, device: Device, pages: list[PageRef], opts: dict, then=None) -> None:
        self.print_btn.setEnabled(False)
        self.progress.setRange(0, len(pages))
        self.progress.setValue(0)
        self.progress.show()
        self.message.emit(tr("Printing…"))

        def job(progress, uri):
            print_pages(uri, pages, progress=lambda i, n: progress((i, n)), **opts)

        def on_progress(p):
            i, n = p
            self.progress.setValue(i)
            self.message.emit(tr("Preparing page {i} of {n}…", i=i, n=n))

        def finished(error=None):
            self.progress.hide()
            self.print_btn.setEnabled(True)
            if error:
                self.alert.emit("error", tr("Print failed"), str(error))
                return
            self.message.emit(tr("Sent to printer."))
            detail = tr("{n} page(s)", n=len(pages))
            if opts.get("copies", 1) > 1:
                detail += f"  ×  {opts['copies']}"
            self.toast.emit(tr("Sent to printer."), f"{opts['job_name']}  ·  {detail}", None)
            if then:
                then()

        run_task(job, device.ipp_uri, on_progress=on_progress,
                 on_done=lambda _: finished(), on_error=finished)
