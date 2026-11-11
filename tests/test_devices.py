"""Several devices in the search, and devices that only print – no network, fake printer/scanner."""
import os
import socket
import time
from types import SimpleNamespace

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PySide6.QtCore import QCoreApplication, QSettings  # noqa: E402
from PySide6.QtWidgets import QApplication  # noqa: E402

from glassbed import config, i18n  # noqa: E402
from glassbed.discovery import SERVICES, Device, add_service, devices_from  # noqa: E402
from glassbed.gui import main_window  # noqa: E402

NO_SCANNER = "This device cannot scan – printing only."


@pytest.fixture(autouse=True)
def no_network(monkeypatch):
    attempts = []

    def refuse(*args, **kwargs):
        attempts.append(args)
        raise OSError("network disabled in tests")

    monkeypatch.setattr(socket.socket, "connect", refuse)
    monkeypatch.setattr(socket, "create_connection", refuse)
    monkeypatch.setattr(socket, "getaddrinfo", refuse)
    yield
    assert attempts == [], f"network was attempted: {attempts}"


# -- search: one entry per device, also printers that only announce _ipps ------------------------
def test_three_devices_with_scanner_hints():
    found = {}
    add_service(found, "_ipp._tcp.local.", "Office Laser._ipp._tcp.local.", "192.168.1.20", 631,
                {"rp": "ipp/print", "ty": "Office Laser"})
    add_service(found, "_uscan._tcp.local.", "HP MFP._uscan._tcp.local.", "192.168.1.10", 80,
                {"rs": "eSCL", "ty": "HP Color Laser MFP 179fnw"})
    add_service(found, "_ipp._tcp.local.", "HP MFP._ipp._tcp.local.", "192.168.1.10", 631,
                {"rp": "ipp/print", "ty": "HP Color Laser MFP 179fnw"})
    add_service(found, "_ipps._tcp.local.", "Brother._ipps._tcp.local.", "192.168.1.30", 443,
                {"rp": "ipp/print", "ty": "Brother HL"})
    devices = devices_from(found)
    assert [(d.name, d.host, d.scanner) for d in devices] == [
        ("Brother HL", "192.168.1.30", False),
        ("HP Color Laser MFP 179fnw", "192.168.1.10", True),
        ("Office Laser", "192.168.1.20", False),
    ]
    brother, hp, _ = devices
    assert hp.escl_url == "http://192.168.1.10:80/eSCL/" and hp.ipp_uri == "ipp://192.168.1.10:631/ipp/print"
    assert brother.ipp_uri == "ipp://192.168.1.30:631/ipp/print"      # plain IPP on 631, not the TLS port


def test_ipp_wins_over_ipps_on_the_same_host():
    found = {}
    add_service(found, "_ipps._tcp.local.", "P._ipps._tcp.local.", "192.168.1.5", 443, {"rp": "ipp/print"})
    add_service(found, "_ipp._tcp.local.", "P._ipp._tcp.local.", "192.168.1.5", 8631, {"rp": "printers/p"})
    assert devices_from(found)[0].ipp_uri == "ipp://192.168.1.5:8631/printers/p"


def test_browsed_services_and_manual_entry():
    assert SERVICES == ["_uscan._tcp.local.", "_ipp._tcp.local.", "_ipps._tcp.local."]
    assert Device.from_host("192.168.1.9").scanner is None          # not known until selected


# -- the window with a device that only prints ----------------------------------------------------
@pytest.fixture
def window(monkeypatch, tmp_path):
    app = QApplication.instance() or QApplication([])
    old = i18n.LANG
    i18n.set_language("en")
    settings = QSettings(str(tmp_path / "glassbed.ini"), QSettings.Format.IniFormat)
    settings.setValue("device/host", "192.168.250.10")
    settings.setValue("device/name", "Test printer")
    settings.setValue("update/asked", True)
    monkeypatch.setattr(config, "settings", lambda: settings)
    state = {"scanner": False, "online": True}

    class FakeIpp:
        def __init__(self, uri, timeout=5):
            pass

        def get_info(self):
            if not state["online"]:
                raise OSError("offline")
            return SimpleNamespace(state="idle", state_reasons=[], markers=[], make_and_model="Test printer")

    class FakeEscl:
        def __init__(self, url, timeout=5):
            pass

        def capabilities(self):
            if not state["scanner"]:
                raise OSError("HTTP 404")
            return SimpleNamespace(sources={"Platen": SimpleNamespace(resolutions=[100, 200, 300])})

    monkeypatch.setattr(main_window, "IppPrinter", FakeIpp)
    monkeypatch.setattr(main_window, "EsclScanner", FakeEscl)
    monkeypatch.setattr(main_window, "discover", lambda timeout=3.0: [])
    w = main_window.MainWindow()
    w.state = state
    yield w
    w._closing = True
    w._timer.stop()
    w.close()
    w.deleteLater()
    QCoreApplication.processEvents()
    i18n.LANG = old
    assert app is not None


def wait_for(cond, ms=3000):
    end = time.monotonic() + ms / 1000
    while time.monotonic() < end and not cond():
        QCoreApplication.processEvents()
        time.sleep(0.01)
    QCoreApplication.processEvents()
    return cond()


def test_print_only_device_locks_scanning(window):
    assert wait_for(lambda: not window.scan_tab.can_scan)
    tab = window.scan_tab
    assert not tab.scan_btn.isEnabled()
    assert not any(w.isEnabled() for w in (tab.source, tab.mode, tab.resolution, tab.paper, tab.intent))
    assert not tab.no_scanner.isHidden() and tab.no_scanner.text() == NO_SCANNER
    assert window.tabs.currentWidget() is window.print_tab           # no pages: open on printing
    assert window._device.scanner is False
    assert "Printer only" in window.device_box.itemText(0)
    messages = []
    tab.message.connect(messages.append)
    tab.start_scan()
    assert messages == [NO_SCANNER]


def test_quick_scan_on_a_print_only_device(window):
    assert wait_for(lambda: not window.scan_tab.can_scan)
    started = []
    window.scan_tab.start_scan = lambda: started.append(True)
    window.quick_scan()
    assert started == [] and window.tabs.currentWidget() is window.print_tab


def test_scanner_found_again_unlocks(window):
    assert wait_for(lambda: not window.scan_tab.can_scan)
    window.state["scanner"] = True
    window.refresh_status(load_caps=True)
    assert wait_for(lambda: window.scan_tab.can_scan)
    tab = window.scan_tab
    assert tab.scan_btn.isEnabled() and tab.no_scanner.isHidden()
    assert window._device.scanner is True and "Printer only" not in window.device_box.itemText(0)


def test_offline_device_is_not_called_print_only(window):
    assert wait_for(lambda: not window.scan_tab.can_scan)
    window.state["scanner"] = True
    window.refresh_status(load_caps=True)
    assert wait_for(lambda: window.scan_tab.can_scan)
    window.state["online"] = False
    window.refresh_status(load_caps=True)
    assert wait_for(lambda: window._status[0] == "Offline")
    assert window.scan_tab.can_scan                                   # unknown while offline: unchanged


def test_language_switch_keeps_the_lock(window):
    assert wait_for(lambda: not window.scan_tab.can_scan)
    window._build_ui(window.tabs.currentIndex())
    assert not window.scan_tab.can_scan and not window.scan_tab.scan_btn.isEnabled()
