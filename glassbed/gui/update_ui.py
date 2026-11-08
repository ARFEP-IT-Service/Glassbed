"""Update check in the window: the one-time question and the banner.

Nothing connects to GitHub unless the user agreed ("update/enabled"). The question is asked
once; whatever happens to it (No, Esc, closing the window) counts as No. Glassbed downloads
and starts nothing itself: "Update" opens the download in the browser.
"""
from __future__ import annotations

from PySide6.QtCore import QObject, Qt, QTimer, QUrl
from PySide6.QtGui import QDesktopServices
from PySide6.QtWidgets import QFrame, QHBoxLayout, QLabel, QPushButton, QSystemTrayIcon

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
    """Slim bar under the header: "Glassbed X is available" and what to do about it."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setObjectName("updatebanner")
        self.text = QLabel()
        self.text.setObjectName("updatetext")
        self.update_btn = QPushButton(tr("Update"))
        self.update_btn.setObjectName("primary")
        self.notes_btn = QPushButton(tr("What's new"))
        self.later_btn = QPushButton(tr("Later"))
        self.skip_btn = QPushButton(tr("Skip this version"))
        lay = QHBoxLayout(self)
        lay.setContentsMargins(20, 6, 20, 6)
        lay.setSpacing(8)
        lay.addWidget(self.text, 1)
        for b in (self.update_btn, self.notes_btn, self.later_btn, self.skip_btn):
            b.setCursor(Qt.CursorShape.PointingHandCursor)
            lay.addWidget(b)
        self.setStyleSheet(
            "QFrame#updatebanner {{ background: {raised}; border-bottom: 1px solid {line}; }}"
            "QLabel#updatetext {{ background: transparent; font-weight: 600; }}".format(**theme.T))
        self.hide()

    def show_offer(self, version: str) -> None:
        self.text.setText(tr("Glassbed {version} is available", version=version))
        self.show()


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
        self._checking = False

    # -- wiring ---------------------------------------------------------------
    def attach(self, banner: UpdateBanner) -> None:
        self.banner = banner
        banner.update_btn.clicked.connect(self.update_now)
        banner.notes_btn.clicked.connect(self.open_release_page)
        banner.later_btn.clicked.connect(self.later)
        banner.skip_btn.clicked.connect(self.skip)
        self._refresh_banner()

    def start(self) -> None:
        """At start-up, only if switched on: check once a day."""
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
            self.banner.show_offer(rel.version)
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

    def update_url(self) -> str:
        """Installed with the setup: the new setup's download link; otherwise the release page."""
        rel = self.release
        if rel is not None and self.kind == "installer" and rel.setup_url:
            return rel.setup_url
        return rel.page_url if rel is not None else updates.RELEASES_URL

    def update_now(self) -> None:
        """Open the download in the browser – Glassbed itself downloads and starts nothing."""
        url = self.update_url()
        QDesktopServices.openUrl(QUrl(url))
        if self.release is not None and url == self.release.setup_url:
            self.window.show_alert("info", tr("Glassbed {version} is downloading in your browser",
                                              version=self.release.version),
                                   tr("Start the setup after the download – your settings are kept."))
