"""The "Check device" report: built from fake results, WS-Discovery parsing, the in-window view."""
import os
import socket
import time

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PySide6.QtCore import QCoreApplication  # noqa: E402
from PySide6.QtGui import QGuiApplication  # noqa: E402
from PySide6.QtWidgets import QApplication  # noqa: E402

from glassbed import device_check, i18n  # noqa: E402
from glassbed.device_check import CheckResult, build_report, parse_probe_match  # noqa: E402

PROBE_MATCH = """<?xml version="1.0" encoding="UTF-8"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://www.w3.org/2003/05/soap-envelope"
  xmlns:wsd="http://schemas.xmlsoap.org/ws/2005/04/discovery"
  xmlns:wscn="http://schemas.microsoft.com/windows/2006/08/wdp/scan">
<SOAP-ENV:Body><wsd:ProbeMatches><wsd:ProbeMatch>
<wsa:EndpointReference><wsa:Address>urn:uuid:cfe92100-67c4-11d4-a45f-e0bb9ea82f79</wsa:Address></wsa:EndpointReference>
<wsd:Types>wsdp:Device wprt:PrintDeviceType
  wscn:ScanDeviceType</wsd:Types>
<wsd:XAddrs>http://192.168.178.31:80/WSD/DEVICE</wsd:XAddrs>
</wsd:ProbeMatch></wsd:ProbeMatches></SOAP-ENV:Body></SOAP-ENV:Envelope>"""


@pytest.fixture(autouse=True)
def no_network(monkeypatch):
    def refuse(*args, **kwargs):
        raise AssertionError("network used in a test")

    monkeypatch.setattr(socket.socket, "connect", refuse)
    monkeypatch.setattr(socket.socket, "sendto", refuse)
    monkeypatch.setattr(socket, "create_connection", refuse)


def test_probe_match_parsing():
    assert parse_probe_match(PROBE_MATCH) == ("wsdp:Device wprt:PrintDeviceType wscn:ScanDeviceType",
                                              "http://192.168.178.31:80/WSD/DEVICE")
    assert parse_probe_match("<Envelope><Body><Probe/></Body></Envelope>") is None


def hp():
    return CheckResult(
        host="192.168.178.33", app="Glassbed for Windows 0.3.2", time="2026-11-09T20:45:02+00:00",
        ports={80: "open", 443: "open", 515: "open", 631: "open", 1865: "timeout", 9100: "open"},
        mdns=[("_ipp._tcp", 631, {"ty": "HP Color Laser MFP 178 179", "rp": "ipp/print", "x": "y"}),
              ("_uscan._tcp", 80, {"ty": "HP Color Laser MFP 178 179", "rs": "eSCL"})],
        ipp="ok ipp://192.168.178.33:631/ipp/print make-and-model=\"HP Color Laser MFP 179fnw\"", ipp_ok=True,
        escl="ok http://192.168.178.33:80/eSCL/ScannerCapabilities version=2.63 sources=Platen,Feeder",
        escl_ok=True, wsd_types="wsdp:Device wprt:PrintDeviceType wscn:ScanDeviceType",
        wsd_xaddrs="http://192.168.178.33:8018/wsd")


def epson():
    return CheckResult(
        host="192.168.178.31", app="Glassbed for Windows 0.3.2", time="2026-11-09T21:00:00+00:00",
        ports={80: "open", 443: "open", 515: "open", 631: "closed", 1865: "open", 9100: "open"},
        mdns=[("_printer._tcp", 515, {"ty": "EPSON ET-2710 Series"})],
        ipp="connection refused", escl="HTTP 404",
        wsd_types="wsdp:Device wprt:PrintDeviceType wscn:ScanDeviceType",
        wsd_xaddrs="http://192.168.178.31:80/WSD/DEVICE")


def test_report_for_a_device_glassbed_supports():
    assert build_report(hp()).splitlines() == [
        "Glassbed device check",
        "App: Glassbed for Windows 0.3.2",
        "Time: 2026-11-09T20:45:02+00:00",
        "Host: 192.168.178.33",
        "Ports: 80 open, 443 open, 515 open, 631 open, 1865 timeout, 9100 open",
        'mDNS: _ipp._tcp port 631 ty="HP Color Laser MFP 178 179" rp="ipp/print"',
        'mDNS: _uscan._tcp port 80 ty="HP Color Laser MFP 178 179" rs="eSCL"',
        'IPP: ok ipp://192.168.178.33:631/ipp/print make-and-model="HP Color Laser MFP 179fnw"',
        "eSCL: ok http://192.168.178.33:80/eSCL/ScannerCapabilities version=2.63 sources=Platen,Feeder",
        "WSD: ok types=wsdp:Device wprt:PrintDeviceType wscn:ScanDeviceType xaddrs=http://192.168.178.33:8018/wsd",
        "Verdict: print=IPP, scan=eSCL",
    ]


def test_report_for_a_device_without_ipp_and_escl():
    lines = build_report(epson()).splitlines()
    assert lines[4] == "Ports: 80 open, 443 open, 515 open, 631 closed, 1865 open, 9100 open"
    assert 'mDNS: _printer._tcp port 515 ty="EPSON ET-2710 Series"' in lines
    assert "IPP: connection refused" in lines and "eSCL: HTTP 404" in lines
    assert lines[-1] == "Verdict: print=none, scan=WSD (not supported by Glassbed yet)"


def test_report_without_any_answer():
    r = CheckResult(host="192.168.178.99", app="a", time="t", ports={p: "timeout" for p in device_check.PORTS},
                    ipp="timeout", escl="timeout")
    lines = build_report(r).splitlines()
    assert "mDNS: no services from this host" in lines and "WSD: no answer" in lines
    assert lines[-1] == "Verdict: print=none, scan=none"


def test_check_page_shows_and_copies_the_report():
    app = QApplication.instance() or QApplication([])
    old = i18n.LANG
    i18n.set_language("en")
    from glassbed.gui.device_check_page import DeviceCheckPage
    page = DeviceCheckPage("192.168.178.31", check=lambda host: epson())
    assert not page.busy.isHidden() and not page.copy_btn.isEnabled()
    end = time.monotonic() + 3
    while time.monotonic() < end and page.copy_btn.isEnabled() is False:
        QCoreApplication.processEvents()
        time.sleep(0.01)
    assert page.copy_btn.isEnabled() and page.busy.isHidden()
    assert page.report.toPlainText() == build_report(epson())
    page.copy_btn.click()
    assert QGuiApplication.clipboard().text() == build_report(epson())
    assert page.copied.text() == "Copied."
    page.deleteLater()
    i18n.LANG = old
    assert app is not None
