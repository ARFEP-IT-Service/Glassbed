"""Main window: device bar, status, tabs – and every other view, in this one window."""
from __future__ import annotations

from PySide6.QtCore import Qt, QTimer, QUrl
from PySide6.QtGui import QDesktopServices
from PySide6.QtWidgets import (QApplication, QButtonGroup, QComboBox, QHBoxLayout, QLabel,
                               QMainWindow, QPushButton, QStackedWidget, QToolButton,
                               QVBoxLayout, QWidget)

import sys
from pathlib import Path

from .. import __version__, autostart, brand, config, i18n
from ..discovery import Device, discover
from ..escl import EsclScanner
from ..i18n import tr
from ..ipp import IppPrinter
from . import theme
from .print_tab import PrintTab
from .scan_tab import ScanTab
from .settings_page import SettingsPage
from .overlay import ConfirmOverlay
from .toast import Toast
from .toast import style as toast_style
from .icons import app_icon
from .tray import TrayController
from . import update_ui
from .update_ui import UpdateBanner, UpdateController
from .widgets import CmykStripe, TonerBar
from .worker import run_task



class MainWindow(QMainWindow):
    def __init__(self, files: list[str] | None = None):
        super().__init__()
        self.settings = config.settings()
        self.setWindowTitle(f"Glassbed {__version__}")
        self.setWindowIcon(app_icon())
        self._device: Device | None = None
        self._devices: dict[str, Device] = {}
        self._status = (tr("Connecting…"), theme.T["muted"])
        self._markers: list = []
        self._caps = None
        self.updates = UpdateController(self)

        self._build_ui(int(self.settings.value("ui/tab", 0)))
        self.resize(1180, 780)
        geo = self.settings.value("ui/geometry")
        if geo is not None:
            self.restoreGeometry(geo)

        self._timer = QTimer(self)
        self._timer.timeout.connect(self.refresh_status)
        self._timer.start(30_000)

        self._closing = False
        self.tray = TrayController(self)
        self.tray.set_enabled(self.settings.value("ui/tray", False, type=bool))
        self._repair_autostart()

        host = self.settings.value("device/host", "")
        if host:
            self._set_device(Device.from_host(host, self.settings.value("device/name", host)))
        else:
            self.search_devices()
        if files:
            self.open_files(files)
        self.updates.start()

    def showEvent(self, event) -> None:
        super().showEvent(event)
        if self.updates.needs_question():       # once, when the window is first really visible
            QTimer.singleShot(400, self.updates.ask_once)

    # -- UI -----------------------------------------------------------------
    def _build_ui(self, tab: int) -> None:
        """(Re)build every widget. Called again after a language/theme change – same window."""
        wordmark = QLabel("Glassbed")
        wordmark.setObjectName("wordmark")
        byline = QPushButton("by ARFEP")
        byline.setObjectName("byline")
        byline.setCursor(Qt.CursorShape.PointingHandCursor)
        byline.setToolTip(f"{brand.COMPANY} · {brand.website(i18n.LANG)}")
        byline.clicked.connect(lambda: QDesktopServices.openUrl(QUrl(brand.website(i18n.LANG))))
        self.tab_buttons = QButtonGroup(self)
        scan_tab_btn = QPushButton(tr("Scan"))
        print_tab_btn = QPushButton(tr("Print"))
        for i, b in enumerate((scan_tab_btn, print_tab_btn)):
            b.setObjectName("tab")
            b.setCheckable(True)
            b.setCursor(Qt.CursorShape.PointingHandCursor)
            self.tab_buttons.addButton(b, i)

        self.status_dot = QLabel("●")
        self.status_lbl = QLabel()
        self.status_lbl.setObjectName("status")
        self.device_box = QComboBox()
        self.device_box.setEditable(True)
        self.device_box.setMinimumWidth(320)
        self.device_box.lineEdit().setPlaceholderText(tr("IP address or host name"))
        self.device_box.lineEdit().editingFinished.connect(self._device_edited)
        self.device_box.activated.connect(lambda _: self._device_edited())
        self.search_btn = QToolButton()
        self.search_btn.setText("⟳")
        self.search_btn.setObjectName("icon")
        self.search_btn.setToolTip(tr("Search"))
        self.search_btn.clicked.connect(self.search_devices)
        self.web_btn = QToolButton()
        self.web_btn.setText("↗")
        self.web_btn.setObjectName("icon")
        self.web_btn.setToolTip(tr("Open the printer's built-in web page"))
        self.web_btn.clicked.connect(self._open_web)
        self.toner = TonerBar()
        self.settings_btn = QToolButton()
        self.settings_btn.setText("⚙︎")
        self.settings_btn.setObjectName("icon")
        self.settings_btn.setToolTip(tr("Settings"))
        self.settings_btn.setCursor(Qt.CursorShape.PointingHandCursor)
        self.settings_btn.clicked.connect(self.open_settings)

        head = QHBoxLayout()
        head.setContentsMargins(20, 0, 20, 0)
        head.setSpacing(6)
        head.addWidget(wordmark)
        head.addWidget(byline, 0, Qt.AlignmentFlag.AlignBottom)
        head.addSpacing(24)
        head.addWidget(scan_tab_btn)
        head.addWidget(print_tab_btn)
        head.addStretch()
        head.addWidget(self.status_dot)
        head.addWidget(self.status_lbl)
        head.addSpacing(10)
        head.addWidget(self.device_box)
        head.addWidget(self.search_btn)
        head.addWidget(self.web_btn)
        head.addSpacing(18)
        head.addWidget(self.toner)
        head.addSpacing(12)
        head.addWidget(self.settings_btn)
        self.header = QWidget()
        self.header.setObjectName("header")
        self.header.setLayout(head)
        self.header.setFixedHeight(60)

        self.scan_tab = ScanTab(lambda: self._device, self.settings)
        self.print_tab = PrintTab(lambda: self._device, self.settings)
        self.tabs = QStackedWidget()
        self.tabs.addWidget(self.scan_tab)
        self.tabs.addWidget(self.print_tab)
        self.tab_buttons.idClicked.connect(self.tabs.setCurrentIndex)
        self.tabs.currentChanged.connect(lambda i: self.tab_buttons.button(i).setChecked(True))
        self.tabs.setCurrentIndex(tab)
        self.tab_buttons.button(tab).setChecked(True)
        for t in (self.scan_tab, self.print_tab):
            t.message.connect(lambda m: self.statusBar().showMessage(m, 8000))
            t.toast.connect(self.show_toast)
            t.alert.connect(self.show_alert)
            t.ask.connect(self.ask)
            t.open_page.connect(self.show_page)

        # the tabs plus any temporary view (editor, settings, preview) share one stack
        self.views = QStackedWidget()
        self.views.addWidget(self.tabs)

        central = QWidget()
        central.setObjectName("root")
        lay = QVBoxLayout(central)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(0)
        lay.addWidget(self.header)
        lay.addWidget(CmykStripe())
        self.update_banner = UpdateBanner()
        lay.addWidget(self.update_banner)
        lay.addWidget(self.views, 1)
        self.setCentralWidget(central)          # deletes the previous central widget
        self.toast = Toast(central)
        central.setStyleSheet(toast_style())
        self.statusBar().setSizeGripEnabled(False)

        # restore what the header showed
        self._fill_box()
        self._set_status(*self._status)
        self.toner.set_markers(self._markers)
        self.scan_tab.apply_capabilities(self._caps)
        self.updates.attach(self.update_banner)

    # -- in-window views ----------------------------------------------------
    def show_page(self, page: QWidget) -> None:
        """Show a view (editor, settings, preview) in place of the tabs."""
        self.close_page()
        self.views.addWidget(page)
        self.views.setCurrentWidget(page)
        page.closed.connect(lambda: self.close_page(page))
        for b in self.tab_buttons.buttons():
            b.setEnabled(False)
        self.settings_btn.setEnabled(False)
        page.setFocus()

    def close_page(self, page: QWidget | None = None) -> None:
        current = self.views.currentWidget()
        if current is self.tabs or (page is not None and page is not current):
            return
        self.views.setCurrentWidget(self.tabs)
        self.views.removeWidget(current)
        current.deleteLater()
        for b in self.tab_buttons.buttons():
            b.setEnabled(True)
        self.settings_btn.setEnabled(True)

    def show_toast(self, title: str, detail: str, path=None) -> None:
        self.toast.show_message(title, detail, path)

    def show_alert(self, kind: str, title: str, body: str) -> None:
        action = None
        if kind == "error":                     # something broke: offer ARFEP's IT help
            action = (tr("Get IT help"), lambda: QDesktopServices.openUrl(QUrl(brand.contact(i18n.LANG))))
        self.toast.show_message(title, kind=kind, body=body, action=action)

    def ask(self, title: str, body: str, button: str, callback) -> None:
        self.toast.show_message(title, kind="question", body=body, action=(button, callback))

    def resizeEvent(self, event) -> None:
        super().resizeEvent(event)
        self.toast.reposition()

    # -- single instance ----------------------------------------------------
    def open_files(self, files: list[str]) -> None:
        if files:
            self.close_page()
            self.print_tab.add_files(files)
            self.tabs.setCurrentWidget(self.print_tab)

    def bring_to_front(self, files: list[str] | None = None) -> None:
        """Called when Glassbed is started again: reuse this window instead of a new one."""
        files = files or []
        if any(Path(f).name == autostart.TRAY_FLAG for f in files):
            return                              # started again "into the tray": stay where we are
        if self.isMinimized():
            self.showNormal()
        self.show()
        self.raise_()
        self.activateWindow()
        self.open_files(files)

    # -- tray ---------------------------------------------------------------
    def current_device(self) -> Device | None:
        return self._device

    def quick_scan(self) -> None:
        """Tray: scan with the last used settings; the pages land in the scan tab."""
        self.bring_to_front()
        self.close_page()
        self.tabs.setCurrentWidget(self.scan_tab)
        if self.scan_tab._cancel is None:      # not while a scan is already running
            self.scan_tab.start_scan()

    def quit_app(self) -> None:
        """Tray: really quit – unsaved scans are still protected by the question."""
        if self.scan_tab.has_unsaved():
            self.bring_to_front()
            self._confirm_close()
            return
        self._close_now()

    def quit_for_update(self) -> None:
        """The setup is running and waits for Glassbed to exit; it starts Glassbed again."""
        self._close_now()
        QApplication.quit()

    def _repair_autostart(self) -> None:
        if not getattr(sys, "frozen", False):
            return
        tray, auto = autostart.effective(self.settings.value("ui/tray", False, type=bool),
                                         self.settings.value("ui/autostart", False, type=bool))
        if auto:
            try:
                autostart.ensure()
            except OSError:
                pass                            # registry not writable: keep running without it

    # -- settings -----------------------------------------------------------
    def open_settings(self) -> None:
        page = SettingsPage(self.settings, self.updates)
        page.applied.connect(lambda: self._apply_settings(page))
        self.show_page(page)

    def _apply_settings(self, page: SettingsPage) -> None:
        folder = page.chosen_folder()
        if folder:
            self.settings.setValue("scan/folder", str(folder))
            self.scan_tab.set_default_folder(folder)
        new_theme = page.chosen_theme()
        theme_changed = new_theme != self.settings.value("ui/theme", "system")
        self.settings.setValue("ui/theme", new_theme)
        self._apply_tray(page.chosen_tray(), page.chosen_autostart())
        self._apply_updates(page.chosen_updates())
        language = page.chosen_language()
        if language != i18n.LANG or theme_changed:
            # rebuild after the settings view has closed
            QTimer.singleShot(0, lambda: self._rebuild(language))

    def _apply_updates(self, on: bool) -> None:
        was_on = update_ui.enabled(self.settings)
        self.settings.setValue(update_ui.KEY_ENABLED, on)
        self.settings.setValue(update_ui.KEY_ASKED, True)      # decided here: never ask again
        if on and not was_on:
            self.updates.start()

    def _apply_tray(self, tray: bool, auto: bool) -> None:
        tray, auto = autostart.effective(tray, auto)
        self.settings.setValue("ui/tray", tray)
        self.settings.setValue("ui/autostart", auto)
        self.tray.set_enabled(tray)
        try:
            if auto:
                autostart.enable()
            else:
                autostart.disable()
        except OSError as e:
            self.show_alert("error", tr("Start with Windows"), str(e))

    def _rebuild(self, code: str) -> None:
        """Switch language/theme in this same window, keeping pages, files and settings."""
        self.settings.setValue("ui/language", code)
        i18n.set_language(code)
        theme.apply(QApplication.instance())
        self._save_state()

        old_scan, old_print = self.scan_tab, self.print_tab
        pages = []
        for item in old_scan.grid.ordered_items():
            pid = item.data(Qt.ItemDataRole.UserRole)
            original, edits = old_scan._sources[pid]
            pages.append((original, old_scan._pages[pid][1], edits))
        filename = old_scan.filename.text()
        files = [path for path, _ in old_print._files]
        self._status = (tr("Connecting…"), theme.T["muted"])   # refreshed right after the rebuild

        self._build_ui(self.tabs.currentIndex())

        for original, dpi, edits in pages:
            self.scan_tab._add_page(original, dpi)
            if not edits.is_identity:
                self.scan_tab._set_edits(self.scan_tab.grid.item(self.scan_tab.grid.count() - 1), edits)
        if pages:
            self.scan_tab.filename.setText(filename)
        if files:
            self.print_tab.add_files(files)
        self.statusBar().clearMessage()
        self.tray.retranslate()
        self.refresh_status()

    def _save_state(self) -> None:
        self.settings.setValue("ui/geometry", self.saveGeometry())
        self.settings.setValue("ui/tab", self.tabs.currentIndex())
        self.scan_tab.save_settings()
        self.print_tab.save_settings()

    def closeEvent(self, event) -> None:
        if not self._closing and self.tray.active:
            event.ignore()                      # the X only hides the window into the tray
            self._save_state()
            self.hide()
            self.tray.notify_hidden()
            return
        if not self._closing and self.scan_tab.has_unsaved():
            event.ignore()                      # ask first – inside the window
            self._confirm_close()
            return
        self._save_state()
        super().closeEvent(event)
        if self.tray.active:                    # nothing else keeps the app alive then
            self.tray.set_enabled(False)
            QApplication.quit()

    def _confirm_close(self) -> None:
        if getattr(self, "_close_overlay", None) is not None:
            return
        n = self.scan_tab.grid.count()
        if self.scan_tab._cancel is not None:
            body = tr("A scan is still running. If you close Glassbed now, it is cancelled and the pages are lost.")
        else:
            body = tr("{n} scanned page(s) have not been saved yet. If you close Glassbed now, they are lost.", n=n)

        def save_and_close():
            self.close_page()
            self.tabs.setCurrentWidget(self.scan_tab)
            self.scan_tab.save(then=self._close_now)

        def done():
            self._close_overlay = None

        buttons = [(tr("Cancel"), "", lambda: None),
                   (tr("Close without saving"), "danger", self._close_now)]
        if self.scan_tab._cancel is None:
            buttons.append((tr("Save and close"), "primary", save_and_close))
        self._close_overlay = ConfirmOverlay(
            self.centralWidget(), tr("Unsaved scans"), body,
            [(label, role, (lambda cb=cb: (done(), cb()))) for label, role, cb in buttons],
            on_cancel=done)

    def _close_now(self) -> None:
        self.scan_tab.cancel_scan()
        self._closing = True
        self.close()

    # -- devices ------------------------------------------------------------
    def search_devices(self) -> None:
        self.search_btn.setEnabled(False)
        self.statusBar().showMessage(tr("Searching for devices…"))

        def done(devices):
            self.search_btn.setEnabled(True)
            if not devices:
                self.statusBar().showMessage(tr("No devices found. Enter the IP address manually."), 10000)
                return
            self.statusBar().showMessage(tr("Found {n} device(s).", n=len(devices)), 5000)
            for d in devices:
                self._devices[d.host] = d
            self._fill_box()
            if self._device is None:
                self._set_device(devices[0])

        run_task(lambda _p: discover(3.0), on_done=done, on_error=lambda e: done([]))

    def _fill_box(self) -> None:
        current = self._device.host if self._device else ""
        self.device_box.blockSignals(True)
        self.device_box.clear()
        for d in self._devices.values():
            label = d.host if d.name == d.host else f"{d.name}  ·  {d.host}"
            self.device_box.addItem(label, d.host)
        i = self.device_box.findData(current)
        if i >= 0:
            self.device_box.setCurrentIndex(i)
        else:
            self.device_box.setEditText(current)
        self.device_box.blockSignals(False)

    def _device_edited(self) -> None:
        i = self.device_box.currentIndex()
        text = self.device_box.currentText().strip()
        host = self.device_box.itemData(i) if i >= 0 and self.device_box.itemText(i) == text else None
        host = host or text.split("·")[-1].split("(")[-1].rstrip(")").strip()
        if not host or (self._device and host == self._device.host):
            return
        self._set_device(self._devices.get(host) or Device.from_host(host))

    def _set_device(self, device: Device) -> None:
        self._device = device
        self._devices.setdefault(device.host, device)
        self._fill_box()
        self.settings.setValue("device/host", device.host)
        self.settings.setValue("device/name", device.name)
        self.refresh_status(load_caps=True)

    def refresh_status(self, load_caps: bool = False) -> None:
        device = self._device
        if not device:
            return

        def job(_p, dev):
            info = IppPrinter(dev.ipp_uri, timeout=5).get_info()
            caps = None
            if load_caps:
                try:
                    caps = EsclScanner(dev.escl_url, timeout=5).capabilities()
                except Exception:  # noqa: BLE001 - printer without scanner
                    caps = None
            return dev, info, caps

        def done(result):
            dev, info, caps = result
            if dev is not self._device:
                return
            state = {"idle": (tr("Ready"), theme.T["accent"]), "processing": (tr("Busy"), theme.YELLOW),
                     "stopped": (tr("Stopped"), theme.T["danger"])}.get(info.state, (info.state, theme.T["muted"]))
            text = state[0]
            if info.state_reasons:
                text += " – " + ", ".join(info.state_reasons)
            self._set_status(text, state[1])
            self._markers = info.markers
            self.toner.set_markers(info.markers)
            if info.make_and_model and dev.name == dev.host:
                dev.name = info.make_and_model
                self.settings.setValue("device/name", dev.name)
                self._fill_box()
            if load_caps:
                self._caps = caps
                self.scan_tab.apply_capabilities(caps)

        def failed(_e):
            self._set_status(tr("Offline"), theme.T["danger"])
            self._markers = []
            self.toner.set_markers([])

        run_task(job, device, on_done=done, on_error=failed)

    def _set_status(self, text: str, color: str) -> None:
        self._status = (text, color)
        self.status_lbl.setText(text)
        self.status_dot.setStyleSheet(f"color: {color}; font-size: 11px;")

    def _open_web(self) -> None:
        if self._device:
            QDesktopServices.openUrl(QUrl(f"http://{self._device.host}/"))
