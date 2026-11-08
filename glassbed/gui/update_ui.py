"""Update check in the window: the one-time question, the banner and the update itself.

Nothing connects to GitHub unless the user agreed ("update/enabled"). The question is asked
once; whatever happens to it (No, Esc, closing the window) counts as No.
"""
from __future__ import annotations

import threading

from PySide6.QtCore import QObject, Qt, QTimer, QUrl
from PySide6.QtGui import QDesktopServices
from PySide6.QtWidgets import (QFrame, QHBoxLayout, QLabel, QProgressBar, QPushButton,
                               QSystemTrayIcon)

from .. import __version__, updates
from ..i18n import tr
from . import theme
from .overlay import ConfirmOverlay
from .worker import run_task

KEY_ASKED, KEY_ENABLED = "update/asked", "update/enabled"
KEY_LAST, KEY_SKIPPED = "update/last_check", "update/skipped"
START_DELAY_MS = 4000


def enabled(settings) -> bool:
    return settings.value(KEY_ENABLED, False, type=bool)


class UpdateBanner(QFrame):
    """Slim bar under the header: "Glassbed X is available" + actions, or the download progress."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setObjectName("updatebanner")
        self.text = QLabel()
        self.text.setObjectName("updatetext")
        self.progress = QProgressBar()
        self.progress.setFixedWidth(220)
        self.progress.setTextVisible(False)
        self.amount = QLabel()
        self.amount.setObjectName("hint")
        self.update_btn = QPushButton(tr("Update"))
        self.update_btn.setObjectName("primary")
        self.notes_btn = QPushButton(tr("What's new"))
        self.later_btn = QPushButton(tr("Later"))
        self.skip_btn = QPushButton(tr("Skip this version"))
        self.cancel_btn = QPushButton(tr("Cancel"))
        lay = QHBoxLayout(self)
        lay.setContentsMargins(20, 6, 20, 6)
        lay.setSpacing(8)
        lay.addWidget(self.text, 1)
        lay.addWidget(self.amount)
        lay.addWidget(self.progress)
        for b in (self.update_btn, self.notes_btn, self.later_btn, self.skip_btn, self.cancel_btn):
            b.setCursor(Qt.CursorShape.PointingHandCursor)
            lay.addWidget(b)
        self.setStyleSheet(
            "QFrame#updatebanner {{ background: {raised}; border-bottom: 1px solid {line}; }}"
            "QLabel#updatetext {{ background: transparent; font-weight: 600; }}".format(**theme.T))
        self.hide()

    def show_offer(self, version: str, can_update: bool) -> None:
        self.text.setText(tr("Glassbed {version} is available", version=version))
        self.progress.hide()
        self.amount.hide()
        self.cancel_btn.hide()
        self.update_btn.setVisible(can_update)
        for b in (self.notes_btn, self.later_btn, self.skip_btn):
            b.show()
        self.show()

    def show_progress(self, version: str) -> None:
        self.text.setText(tr("Downloading Glassbed {version}…", version=version))
        self.progress.setRange(0, 0)
        self.amount.setText("")
        self.amount.show()
        self.progress.show()
        self.cancel_btn.show()
        self.cancel_btn.setEnabled(True)
        for b in (self.update_btn, self.notes_btn, self.later_btn, self.skip_btn):
            b.hide()
        self.show()

    def set_progress(self, done: int, total: int) -> None:
        if total > 0:
            self.progress.setRange(0, 1000)
            self.progress.setValue(int(done * 1000 / total))
            self.amount.setText(f"{done / 1e6:.1f} / {total / 1e6:.1f} MB")


class UpdateController(QObject):
    """Owned by the main window. ``attach`` is called again whenever the window rebuilds its UI."""

    def __init__(self, window):
        super().__init__(window)
        self.window = window
        self.settings = window.settings
        self.kind = updates.install_kind()
        self.release: updates.Release | None = None
        self.banner: UpdateBanner | None = None
        self._dismissed = False                 # "Later": hidden until the next check
        self._question = None
        self._cancel: threading.Event | None = None
        self._checking = False

    # -- wiring ---------------------------------------------------------------
    def attach(self, banner: UpdateBanner) -> None:
        self.banner = banner
        banner.update_btn.clicked.connect(self.update_now)
        banner.notes_btn.clicked.connect(self.open_release_page)
        banner.later_btn.clicked.connect(self.later)
        banner.skip_btn.clicked.connect(self.skip)
        banner.cancel_btn.clicked.connect(self.cancel_download)
        if self._cancel is not None and self.release:
            banner.show_progress(self.release.version)
        else:
            self._refresh_banner()

    def start(self) -> None:
        """At start-up: tidy old downloads and, only if switched on, check once a day."""
        updates.cleanup_temp()
        if enabled(self.settings) and updates.check_due(self.settings.value(KEY_LAST, None)):
            QTimer.singleShot(START_DELAY_MS, lambda: self.check(silent=True))

    # -- the one-time question ------------------------------------------------
    def needs_question(self) -> bool:
        return not self.settings.value(KEY_ASKED, False, type=bool)

    def ask_once(self) -> ConfirmOverlay | None:
        """Ask whether to look for updates. Asked exactly once: the answer is No until Yes is clicked."""
        if not self.needs_question() or self._question is not None:
            return None
        self.settings.setValue(KEY_ASKED, True)
        self.settings.setValue(KEY_ENABLED, False)     # closing the window or Esc = No
        self.settings.sync()

        def answer(yes: bool) -> None:
            self._question = None
            self.settings.setValue(KEY_ENABLED, yes)
            self.settings.sync()
            if yes:
                self.check(silent=True)

        body = tr("Glassbed can look for a new version on GitHub – at most once a day. GitHub sees your "
                  "IP address when it does. Nothing is installed automatically; you decide each time. "
                  "You can change this later in the settings.")
        # "No" is the default button (focused, Enter); Esc and closing the window also mean No
        self._question = ConfirmOverlay(
            self.window.centralWidget(), tr("Check for updates?"), body,
            [(tr("Yes"), "", lambda: answer(True)), (tr("No"), "primary", lambda: answer(False))],
            on_cancel=lambda: answer(False))
        return self._question

    # -- checking -------------------------------------------------------------
    def check(self, silent: bool, on_result=None) -> None:
        """Ask GitHub once. ``silent``: errors are not shown (start-up check)."""
        if self._checking:
            return
        self._checking = True
        self.settings.setValue(KEY_LAST, updates.stamp())      # also counts when offline

        def done(release):
            self._checking = False
            self.release = release
            self._dismissed = False
            new = updates.should_notify(release, __version__, self.settings.value(KEY_SKIPPED, ""))
            if not silent and release is not None and updates.is_newer(release.version):
                new = True                              # "Check now" also shows a skipped version
            self._refresh_banner(force=new)
            if new:
                self._notify_tray(release)
            if on_result:
                on_result(release if new else None, None)

        def failed(exc):
            self._checking = False
            if on_result:
                on_result(None, exc)

        run_task(lambda _p: updates.fetch_latest(), on_done=done, on_error=failed)

    def _refresh_banner(self, force: bool = False) -> None:
        if self.banner is None:
            return
        rel = self.release
        show = rel is not None and not self._dismissed and (
            force or updates.should_notify(rel, __version__, self.settings.value(KEY_SKIPPED, "")))
        if show:
            self.banner.show_offer(rel.version, self.kind == "installer" and rel.setup_url is not None)
        else:
            self.banner.hide()

    def _notify_tray(self, release) -> None:
        tray = getattr(self.window, "tray", None)
        if tray is not None and tray.icon is not None:
            tray.icon.showMessage("Glassbed", tr("Glassbed {version} is available", version=release.version),
                                  QSystemTrayIcon.MessageIcon.Information, 8000)

    # -- banner actions ---------------------------------------------------------
    def open_release_page(self) -> None:
        url = self.release.page_url if self.release else updates.RELEASES_URL
        QDesktopServices.openUrl(QUrl(url))

    def later(self) -> None:
        self._dismissed = True
        self._refresh_banner()

    def skip(self) -> None:
        if self.release:
            self.settings.setValue(KEY_SKIPPED, self.release.version)
        self._dismissed = True
        self._refresh_banner()

    def update_now(self) -> None:
        rel = self.release
        if rel is None:
            return
        if self.kind != "installer" or not rel.setup_url:
            self.open_release_page()            # portable / source / macOS / Linux: only the page
            return
        if self.window.scan_tab.has_unsaved():
            self.window.show_alert("info", tr("Save your scans first"),
                                   tr("Glassbed restarts for the update. Save or remove the scanned pages first."))
            return
        self._cancel = threading.Event()
        cancel = self._cancel
        folder = updates.new_temp_dir()
        self.banner.show_progress(rel.version)

        def job(progress):
            return updates.download(rel, folder, lambda d, t: progress((d, t)), cancel.is_set)

        def done(setup):
            self._cancel = None
            try:
                updates.start_installer(setup)
            except OSError as e:
                updates.cleanup_temp()
                self._refresh_banner(force=True)
                self.window.show_alert("error", tr("Update failed"), str(e))
                return
            self.window.quit_for_update()

        def failed(exc):
            self._cancel = None
            updates.cleanup_temp()
            self._refresh_banner(force=True)
            if not isinstance(exc, updates.Cancelled):
                self.window.show_alert("error", tr("Update failed"), str(exc))

        run_task(job, on_done=done, on_error=failed,
                 on_progress=lambda v: self.banner and self.banner.set_progress(*v))

    def cancel_download(self) -> None:
        if self._cancel is not None:
            self._cancel.set()
            if self.banner:
                self.banner.cancel_btn.setEnabled(False)
