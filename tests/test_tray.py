"""Tray settings, start-with-Windows entry and low-toner warnings – no registry, no Qt event loop."""
import sys
from datetime import date, timedelta

import pytest

from glassbed import autostart, toner_alerts
from glassbed.ipp import Marker

EXE = r"C:\Users\someone\AppData\Local\Programs\Glassbed\Glassbed.exe"


# -- settings ---------------------------------------------------------------
def test_settings_defaults_and_installer_strings(tmp_path):
    """Both options are off by default; the installer's REG_SZ "true" reads as True."""
    from PySide6.QtCore import QSettings
    s = QSettings(str(tmp_path / "glassbed.ini"), QSettings.Format.IniFormat)
    assert s.value("ui/tray", False, type=bool) is False
    assert s.value("ui/autostart", False, type=bool) is False
    s.setValue("ui/tray", "true")
    s.setValue("ui/autostart", "true")
    assert s.value("ui/tray", False, type=bool) is True
    assert s.value("ui/autostart", False, type=bool) is True


def test_autostart_requires_tray(monkeypatch):
    monkeypatch.setattr(autostart, "supported", lambda: True)
    assert autostart.effective(False, True) == (False, False)
    assert autostart.effective(True, False) == (True, False)
    assert autostart.effective(True, True) == (True, True)
    monkeypatch.setattr(autostart, "supported", lambda: False)     # macOS / Linux
    assert autostart.effective(True, True) == (True, False)


# -- start with Windows (fake registry) --------------------------------------
class FakeWinreg:
    HKEY_CURRENT_USER = "HKCU"
    KEY_READ, KEY_SET_VALUE, REG_SZ = 1, 2, 1

    class _Key:
        def __init__(self, store):
            self.store = store

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

    def __init__(self):
        self.keys: dict[tuple, dict] = {}

    def OpenKey(self, root, path, reserved=0, access=0):
        if (root, path) not in self.keys:
            raise FileNotFoundError(path)
        return self._Key(self.keys[(root, path)])

    def CreateKeyEx(self, root, path, reserved=0, access=0):
        return self._Key(self.keys.setdefault((root, path), {}))

    def QueryValueEx(self, key, name):
        if name not in key.store:
            raise FileNotFoundError(name)
        return key.store[name], self.REG_SZ

    def SetValueEx(self, key, name, reserved, kind, value):
        key.store[name] = value

    def DeleteValue(self, key, name):
        if name not in key.store:
            raise FileNotFoundError(name)
        del key.store[name]

    def run_values(self):
        return self.keys.get((self.HKEY_CURRENT_USER, autostart.RUN_KEY), {})


@pytest.fixture
def registry(monkeypatch):
    fake = FakeWinreg()
    monkeypatch.setattr(autostart, "_winreg", lambda: fake)
    monkeypatch.setattr(autostart, "supported", lambda: True)
    monkeypatch.setattr(sys, "frozen", True, raising=False)
    monkeypatch.setattr(sys, "executable", EXE)
    monkeypatch.setenv("GLASSBED_PROFILE", "Glassbed")
    return fake


def test_autostart_entry_create_and_remove(registry):
    assert autostart.current() is None
    autostart.enable()
    assert registry.run_values() == {"Glassbed": f'"{EXE}" --tray'}       # quoted path + flag
    assert autostart.current() == f'"{EXE}" --tray'
    autostart.disable()
    assert registry.run_values() == {}
    autostart.disable()                                                   # already gone: no error


def test_autostart_repairs_moved_app(registry, monkeypatch):
    autostart.enable('"C:\\old place\\Glassbed.exe" --tray')
    assert autostart.ensure() is True                                     # points elsewhere → rewritten
    assert registry.run_values()["Glassbed"] == f'"{EXE}" --tray'
    assert autostart.ensure() is False                                    # already right → untouched


def test_autostart_other_profile_never_touches_real_entry(registry, monkeypatch):
    registry.CreateKeyEx(FakeWinreg.HKEY_CURRENT_USER, autostart.RUN_KEY)
    registry.run_values()["Glassbed"] = "real entry"
    monkeypatch.setenv("GLASSBED_PROFILE", "Glassbed-test")
    assert autostart.value_name() == "Glassbed (Glassbed-test)"
    autostart.enable()
    autostart.disable()
    assert registry.run_values() == {"Glassbed": "real entry"}


def test_autostart_noop_outside_windows(monkeypatch):
    monkeypatch.setattr(autostart, "supported", lambda: False)
    monkeypatch.setattr(autostart, "_winreg", lambda: pytest.fail("registry used"))
    autostart.enable()
    autostart.disable()
    assert autostart.current() is None
    assert autostart.ensure() is False


# -- toner warnings -----------------------------------------------------------
def toner(name, level):
    return Marker(name=name, level=level, color="#000000")


def test_toner_threshold():
    today = date(2026, 11, 8)
    due = toner_alerts.alerts_due([toner("Cyan Toner", 14), toner("Magenta Toner", 15),
                                   toner("Yellow Toner", -1), toner("Black Toner", 0)], {}, today)
    assert [m.name for m in due] == ["Cyan Toner", "Black Toner"]         # 15 % and unknown: no warning


def test_toner_once_per_day_per_colour():
    today = date(2026, 11, 8)
    cyan, yellow = toner("Cyan Toner", 9), toner("Yellow Toner", 12)
    last = toner_alerts.record({}, toner_alerts.alerts_due([cyan], {}, today), today)
    assert toner_alerts.alerts_due([cyan], last, today) == []             # same day: quiet
    assert toner_alerts.alerts_due([cyan, yellow], last, today) == [yellow]   # colours are independent
    assert toner_alerts.alerts_due([cyan], last, today + timedelta(days=1)) == [cyan]   # next day again


def test_toner_names():
    assert toner_alerts.alert_key("Cyan Toner_S/N_:CRUM-1") == "Cyan_Toner_S_N_CRUM_1"
    assert toner_alerts.display_name("Cyan Toner") == "Cyan"
    assert toner_alerts.display_name("Toner") == "Toner"
