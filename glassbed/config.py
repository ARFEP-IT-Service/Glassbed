"""Where Glassbed keeps its settings.

``GLASSBED_PROFILE`` selects a separate settings profile – used by tests and screenshots so
they never touch the user's real settings.
"""
from __future__ import annotations

import os

ORGANIZATION = "Glassbed"
LEGACY_ORGANIZATION = "OpenMFP"         # the project's earlier name


def profile() -> str:
    return os.environ.get("GLASSBED_PROFILE", "Glassbed")


def settings():
    from PySide6.QtCore import QSettings
    return QSettings(ORGANIZATION, profile())


def migrate_legacy_settings() -> bool:
    """Copy settings saved under the old name once, so nothing is lost after the rename."""
    from PySide6.QtCore import QSettings
    new = settings()
    if new.allKeys() or profile() != "Glassbed":
        return False
    old = QSettings(LEGACY_ORGANIZATION, LEGACY_ORGANIZATION)
    keys = old.allKeys()
    for key in keys:
        new.setValue(key, old.value(key))
    new.sync()
    return bool(keys)
