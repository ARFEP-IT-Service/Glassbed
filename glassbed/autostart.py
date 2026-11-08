"""Start Glassbed with Windows: a value under HKCU\\...\\Run (per user, no admin rights).

Only Windows is supported; elsewhere every function is a no-op. The value name is
"Glassbed" for the normal settings profile and "Glassbed (<profile>)" for any other
GLASSBED_PROFILE, so tests and experiments never touch the real entry.
"""
from __future__ import annotations

import sys
from pathlib import Path

from . import config

RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"
TRAY_FLAG = "--tray"


def _winreg():
    """The registry module (replaced by a fake in the tests)."""
    import winreg
    return winreg


def supported() -> bool:
    return sys.platform == "win32"


def effective(tray: bool, autostart: bool) -> tuple[bool, bool]:
    """Starting with Windows only makes sense with the tray icon: the app starts hidden there."""
    return tray, bool(autostart and tray and supported())


def value_name(profile: str | None = None) -> str:
    profile = profile or config.profile()
    return "Glassbed" if profile == "Glassbed" else f"Glassbed ({profile})"


def command() -> str:
    """What Windows runs at sign-in: the installed Glassbed.exe, started into the tray."""
    if getattr(sys, "frozen", False):
        return f'"{sys.executable}" {TRAY_FLAG}'
    exe = Path(sys.executable)
    pythonw = exe.with_name("pythonw.exe")                  # no console window at sign-in
    return f'"{pythonw if pythonw.exists() else exe}" -m glassbed {TRAY_FLAG}'


def current() -> str | None:
    """The registered command, or None when there is no entry."""
    if not supported():
        return None
    reg = _winreg()
    try:
        with reg.OpenKey(reg.HKEY_CURRENT_USER, RUN_KEY, 0, reg.KEY_READ) as key:
            value, _kind = reg.QueryValueEx(key, value_name())
            return str(value)
    except OSError:
        return None


def enable(cmd: str | None = None) -> None:
    if not supported():
        return
    reg = _winreg()
    with reg.CreateKeyEx(reg.HKEY_CURRENT_USER, RUN_KEY, 0, reg.KEY_SET_VALUE) as key:
        reg.SetValueEx(key, value_name(), 0, reg.REG_SZ, cmd or command())


def disable() -> None:
    if not supported():
        return
    reg = _winreg()
    try:
        with reg.OpenKey(reg.HKEY_CURRENT_USER, RUN_KEY, 0, reg.KEY_SET_VALUE) as key:
            reg.DeleteValue(key, value_name())
    except OSError:
        pass                                                # nothing registered


def ensure(cmd: str | None = None) -> bool:
    """Re-register when the entry is missing or points elsewhere (e.g. the app was moved).

    Returns True when the entry had to be written.
    """
    if not supported():
        return False
    cmd = cmd or command()
    if current() == cmd:
        return False
    enable(cmd)
    return True
