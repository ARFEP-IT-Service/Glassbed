"""Entry point: ``python -m glassbed`` starts the GUI, ``python -m glassbed scan …`` the CLI.

``--tray`` starts with the icon in the notification area and without the window (used by
"start with Windows").
"""
from __future__ import annotations

import sys

CLI_COMMANDS = {"list", "status", "scan", "print", "-h", "--help", "--host"}
TRAY_FLAG = "--tray"


def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1] in CLI_COMMANDS:
        from .cli import main as cli_main
        cli_main()
        return

    from PySide6.QtWidgets import QApplication

    from .single_instance import InstanceServer, hand_over

    args = sys.argv[1:]
    start_in_tray = TRAY_FLAG in args
    files = [a for a in args if a != TRAY_FLAG]
    app = QApplication(sys.argv)
    # already running: that window takes over, no second one. A start "into the tray"
    # only passes the flag on, so the running window stays where it is.
    if hand_over([TRAY_FLAG] if start_in_tray and not files else files):
        return

    from . import config
    config.migrate_legacy_settings()    # keep folder, printer, language from the old "OpenMFP"

    from .gui import theme
    from .gui.main_window import MainWindow

    app.setApplicationName("Glassbed")
    app.setOrganizationName("Glassbed")
    app.setStyle("Fusion")
    from .gui.icons import app_icon
    app.setWindowIcon(app_icon())
    theme.apply(app)
    window = MainWindow(files=files)
    window.instance_server = InstanceServer(window.bring_to_front)   # keep it alive with the window
    if not (start_in_tray and window.tray.active):   # no tray available: show the window anyway
        window.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
