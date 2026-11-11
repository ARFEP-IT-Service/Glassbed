"""Only devices on the local network – address ranges, every connection and every redirect hop."""
import io
import os
import socket
import time
import urllib.error
import urllib.request

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from glassbed import device_check, escl, ipp  # noqa: E402
from glassbed.discovery import add_service, devices_from  # noqa: E402
from glassbed.lan import NotLocalNetwork, check_url, is_local_host  # noqa: E402

LOCAL = ["192.168.178.33", "10.0.0.5", "172.16.0.1", "172.31.255.254", "169.254.10.20",
         "fd12:3456::1", "fe80::1", "[fe80::1%eth0]", "FE80::1", "::ffff:192.168.1.5",
         "printer.local", "EPSON1234.local.", " 192.168.1.2 "]
NOT_LOCAL = ["8.8.8.8", "1.1.1.1", "172.32.0.1", "172.15.255.255", "192.169.0.1", "11.0.0.1",
             "127.0.0.1", "0.0.0.0", "255.255.255.255", "192.0.2.10", "2001:db8::1", "2a02:8071::1",
             "::1", "::ffff:8.8.8.8", "printer.fritz.box", "example.com", "local", ".local", "", "localhost"]


@pytest.fixture
def connects(monkeypatch):
    """Every connection attempt is recorded and refused."""
    seen = []

    def refuse(*args, **kwargs):
        seen.append(args)
        raise OSError("network disabled in tests")

    monkeypatch.setattr(socket.socket, "connect", refuse)
    monkeypatch.setattr(socket.socket, "connect_ex", refuse)
    monkeypatch.setattr(socket.socket, "sendto", refuse)
    monkeypatch.setattr(socket, "create_connection", refuse)
    return seen


@pytest.mark.parametrize("host", LOCAL)
def test_local_addresses(host):
    assert is_local_host(host)


@pytest.mark.parametrize("host", NOT_LOCAL)
def test_other_addresses_are_refused(host):
    assert not is_local_host(host)


# -- no connection at all to a public address -------------------------------------------------
def test_escl_refuses_a_public_scanner(connects):
    with pytest.raises(NotLocalNetwork):
        escl.EsclScanner("http://8.8.8.8/eSCL/", timeout=1).capabilities()
    assert connects == []


def test_ipp_refuses_a_public_printer(connects):
    with pytest.raises(NotLocalNetwork):
        ipp.IppPrinter("ipp://8.8.8.8:631/ipp/print", timeout=1).get_info()
    assert connects == []


def test_device_check_refuses_a_public_host(connects):
    with pytest.raises(NotLocalNetwork):
        device_check.run_check("8.8.8.8")
    assert connects == []


def test_search_ignores_answers_from_outside():
    found = {}
    add_service(found, "_ipp._tcp.local.", "Evil._ipp._tcp.local.", "8.8.8.8", 631, {"ty": "Evil"})
    add_service(found, "_ipp._tcp.local.", "HP._ipp._tcp.local.", "192.168.1.20", 631, {"ty": "HP"})
    assert [d.host for d in devices_from(found)] == ["192.168.1.20"]


# -- redirects: every hop is checked -----------------------------------------------------------
def test_escl_redirect_only_to_the_local_network():
    handler = escl.LocalRedirects()
    req = urllib.request.Request("http://192.168.1.20/eSCL/ScannerCapabilities")
    for target in ("http://8.8.8.8/eSCL/ScannerCapabilities", "https://example.com/x",
                   "http://127.0.0.1/x", "http://[2001:db8::1]/x"):
        with pytest.raises(NotLocalNetwork):
            handler.redirect_request(req, None, 302, "Found", {}, target)
    for target in ("http://192.168.1.20:8080/eSCL/ScannerCapabilities", "http://192.168.1.21/eSCL/x"):
        new = handler.redirect_request(req, None, 302, "Found", {}, target)
        assert new is not None and new.full_url == target
    assert escl.LocalRedirects.max_redirections == 5


class FakeResponse:
    def __init__(self, status, location=None, body=b""):
        self.status, self._location, self._body = status, location, body

    def getheader(self, name):
        return self._location if name == "Location" else None

    def read(self):
        return self._body


def fake_ipp(monkeypatch, answers):
    """http.client.HTTPConnection that answers from ``answers[(host, port, path)]``."""
    calls = []

    class Conn:
        def __init__(self, host, port, timeout=None):
            self.host, self.port = host, port

        def request(self, method, path, body=None, headers=None):
            calls.append((self.host, self.port, path))
            self.key = (self.host, self.port, path)

        def getresponse(self):
            return answers[self.key]

        def close(self):
            pass

    monkeypatch.setattr(ipp.http.client, "HTTPConnection", Conn)
    return calls


OK_BODY = ipp.encode_request(0x0000, "ipp://x/ipp/print")[:8]    # status 0x0000 + request id


def test_ipp_redirect_to_a_public_address_is_refused(monkeypatch):
    calls = fake_ipp(monkeypatch, {
        ("192.168.1.20", 631, "/ipp/print"): FakeResponse(307, "http://8.8.8.8:631/ipp/print")})
    with pytest.raises(NotLocalNetwork):
        ipp.IppPrinter("ipp://192.168.1.20:631/ipp/print", timeout=1).get_info()
    assert calls == [("192.168.1.20", 631, "/ipp/print")]           # never sent to 8.8.8.8


def test_ipp_redirect_within_the_local_network_is_followed(monkeypatch):
    calls = fake_ipp(monkeypatch, {
        ("192.168.1.20", 631, "/ipp/print"): FakeResponse(307, "/ipp/printer"),
        ("192.168.1.20", 631, "/ipp/printer"): FakeResponse(308, "http://192.168.1.21:631/ipp"),
        ("192.168.1.21", 631, "/ipp"): FakeResponse(200, body=b"\x02\x00\x00\x00\x00\x00\x00\x01\x03")})
    info = ipp.IppPrinter("ipp://192.168.1.20:631/ipp/print", timeout=1).get_info()
    assert info.state == "unknown"
    assert calls[-1] == ("192.168.1.21", 631, "/ipp")


def test_ipp_redirect_loop_stops(monkeypatch):
    fake_ipp(monkeypatch, {("192.168.1.20", 631, "/ipp/print"): FakeResponse(307, "/ipp/print")})
    with pytest.raises(ipp.IppError, match="redirects"):
        ipp.IppPrinter("ipp://192.168.1.20:631/ipp/print", timeout=1).get_info()


def test_check_url():
    check_url("http://192.168.1.20/eSCL/")
    with pytest.raises(NotLocalNetwork):
        check_url("http://8.8.8.8/eSCL/")


# -- the window: a typed public address is refused with a message -------------------------------
def test_window_refuses_a_public_address(monkeypatch, tmp_path, connects):
    from PySide6.QtCore import QCoreApplication, QSettings
    from PySide6.QtWidgets import QApplication

    from glassbed import config, i18n
    from glassbed.gui import main_window

    app = QApplication.instance() or QApplication([])
    i18n.set_language("en")
    settings = QSettings(str(tmp_path / "g.ini"), QSettings.Format.IniFormat)
    settings.setValue("update/asked", True)
    settings.setValue("device/host", "8.8.8.8")                      # e.g. saved by an older version
    monkeypatch.setattr(config, "settings", lambda: settings)
    monkeypatch.setattr(main_window, "discover", lambda timeout=3.0: [])
    alerts = []
    monkeypatch.setattr(main_window.MainWindow, "show_alert",
                        lambda self, kind, title, body: alerts.append((kind, title)))
    w = main_window.MainWindow()
    end = time.monotonic() + 1
    while time.monotonic() < end:
        QCoreApplication.processEvents()
        time.sleep(0.01)
    assert w._device is None
    assert alerts == [("info", "Only devices on the local network can be used (8.8.8.8).")]
    w.device_box.setEditText("1.1.1.1")
    w._device_edited()
    w.device_box.setEditText("1.1.1.1")
    w.check_device()
    assert w._device is None and len(alerts) == 3
    assert connects == []
    w._closing = True
    w._timer.stop()
    w.close()
    assert app is not None
