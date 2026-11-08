"""Icon in the notification area: open, quick scan, quit – and low-toner warnings."""
from __future__ import annotations

from datetime import date

from PySide6.QtCore import QObject, QTimer
from PySide6.QtWidgets import QApplication, QMenu, QSystemTrayIcon

from .. import toner_alerts
from ..i18n import tr
from ..ipp import IppPrinter
from .icons import app_icon
from .worker import run_task

ALERT_GROUP = "tray/toner_alert"
FIRST_CHECK_MS = 60_000             # first toner check one minute after the tray appears


def available() -> bool:
    return QSystemTrayIcon.isSystemTrayAvailable()


class TrayController(QObject):
    """Owned by the main window; ``set_enabled`` shows or removes the icon."""

    def __init__(self, window):
        super().__init__(window)
        self.window = window
        self.icon: QSystemTrayIcon | None = None
        self._menu: QMenu | None = None
        self._actions = {}
        self._hint_shown = False
        self._timer = QTimer(self)
        self._timer.setInterval(toner_alerts.INTERVAL_MS)
        self._timer.timeout.connect(self.check_toner)

    @property
    def active(self) -> bool:
        return self.icon is not None

    def set_enabled(self, on: bool) -> None:
        if on and available():
            if self.icon is None:
                self._build()
            self.icon.show()
            # the app keeps running in the tray when the window is closed
            QApplication.setQuitOnLastWindowClosed(False)
            if not self._timer.isActive():
                self._timer.start()
                QTimer.singleShot(FIRST_CHECK_MS, self.check_toner)
        elif self.icon is not None:
            self._timer.stop()
            self.icon.hide()
            self.icon.deleteLater()
            self.icon = None
            self._menu = None
            QApplication.setQuitOnLastWindowClosed(True)

    def _build(self) -> None:
        self.icon = QSystemTrayIcon(app_icon(), self)
        self.icon.setToolTip("Glassbed")
        self._menu = QMenu()
        self._actions = {
            "open": self._menu.addAction("", self.window.bring_to_front),
            "scan": self._menu.addAction("", self.window.quick_scan),
        }
        self._menu.addSeparator()
        self._actions["quit"] = self._menu.addAction("", self.window.quit_app)
        self.icon.setContextMenu(self._menu)
        self.icon.activated.connect(self._activated)
        self.retranslate()

    def retranslate(self) -> None:
        for key, text in (("open", "Open"), ("scan", "Quick scan"), ("quit", "Quit")):
            if key in self._actions:
                self._actions[key].setText(tr(text))

    def _activated(self, reason) -> None:
        if reason in (QSystemTrayIcon.ActivationReason.Trigger,
                      QSystemTrayIcon.ActivationReason.DoubleClick):
            self.window.bring_to_front()

    def notify_hidden(self) -> None:
        """Say once per session where the window went."""
        if self.icon is not None and not self._hint_shown:
            self._hint_shown = True
            self.icon.showMessage("Glassbed", tr("Glassbed keeps running in the notification area."),
                                  QSystemTrayIcon.MessageIcon.Information, 4000)

    # -- toner --------------------------------------------------------------
    def _last_alerts(self) -> dict[str, str]:
        s = self.window.settings
        s.beginGroup(ALERT_GROUP)
        try:
            return {k: str(s.value(k)) for k in s.childKeys()}
        finally:
            s.endGroup()

    def check_toner(self) -> None:
        device = self.window.current_device()
        if self.icon is None or device is None:
            return

        def job(_p, uri):
            return IppPrinter(uri, timeout=5).get_info().markers

        def done(markers):
            if self.icon is None:
                return
            today = date.today()
            due = toner_alerts.alerts_due(markers, self._last_alerts(), today)
            if not due:
                return
            lines = [tr("{name}: {level} % left", name=toner_alerts.display_name(m.name), level=m.level)
                     for m in due]
            self.icon.showMessage(tr("Toner low"), "\n".join(lines),
                                  QSystemTrayIcon.MessageIcon.Warning, 10000)
            for key, stamp in toner_alerts.record({}, due, today).items():
                self.window.settings.setValue(f"{ALERT_GROUP}/{key}", stamp)

        # printer unreachable or busy: stay quiet, the next round tries again
        run_task(job, device.ipp_uri, on_done=done, on_error=lambda _e: None)
