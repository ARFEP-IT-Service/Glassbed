"""Entry point: ``python -m glassbed`` starts the GUI, ``python -m glassbed scan …`` the CLI."""
from __future__ import annotations

import sys

CLI_COMMANDS = {"list", "status", "scan", "print", "-h", "--help", "--host"}


def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1] in CLI_COMMANDS:
        from .cli import main as cli_main
        cli_main()
        return

    from PySide6.QtWidgets import QApplication

    from .single_instance import InstanceServer, hand_over

    files = sys.argv[1:]
    app = QApplication(sys.argv)
    if hand_over(files):            # already running: that window takes over, no second one
        return

    from . import config
    config.migrate_legacy_settings()    # keep folder, printer, language from the old "OpenMFP"

    from .gui import theme
    from .gui.main_window import MainWindow

    app.setApplicationName("Glassbed")
    app.setOrganizationName("Glassbed")
    app.setStyle("Fusion")
    theme.apply(app)
    window = MainWindow(files=files)
    window.instance_server = InstanceServer(window.bring_to_front)   # keep it alive with the window
    window.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
