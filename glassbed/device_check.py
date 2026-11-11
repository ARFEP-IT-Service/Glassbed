"""The "Check device" report: what a printer/scanner offers on the network, as a text report for the developer.

Used when a device does not work with Glassbed: it lists open ports, the Bonjour (mDNS) services of
the host, whether IPP and eSCL answer and whether the device answers WS-Discovery (WSD). The
report contains the device's address, model and protocols – nothing about the user.
"""
from __future__ import annotations

import concurrent.futures
import re
import socket
import struct
import time
import urllib.error
import urllib.request
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone

from . import __version__
from .escl import open_local, parse_capabilities
from .ipp import IppPrinter
from .lan import NotLocalNetwork, check_host

PORTS = (80, 443, 515, 631, 1865, 9100)
MDNS_TYPES = ("_ipp._tcp", "_ipps._tcp", "_uscan._tcp", "_uscans._tcp", "_printer._tcp",
              "_pdl-datastream._tcp", "_scanner._tcp")
TXT_KEYS = ("ty", "rp", "rs", "pdl", "URF")
IPP_PATHS = ("ipp/print", "ipp/printer", "ipp")
WSD_ADDR = ("239.255.255.250", 3702)
WSD_UNSUPPORTED = "WSD (not supported by Glassbed yet)"


@dataclass
class CheckResult:
    host: str
    app: str = f"Glassbed for Windows {__version__}"
    time: str = ""
    ports: dict[int, str] = field(default_factory=dict)          # port → open / closed / timeout
    mdns: list[tuple[str, int, dict[str, str]]] = field(default_factory=list)   # type, port, txt
    ipp: str = ""                                                # "ok …" or the error
    ipp_ok: bool = False
    escl: str = ""
    escl_ok: bool = False
    wsd_types: str = ""
    wsd_xaddrs: str = ""


# --------------------------------------------------------------------------- report (pure)
def verdict(r: CheckResult) -> str:
    scan = "none"
    if r.escl_ok:
        scan = "eSCL"
    elif re.search(r"ScanDeviceType|ScannerServiceType", r.wsd_types):
        scan = WSD_UNSUPPORTED
    return f"print={'IPP' if r.ipp_ok else 'none'}, scan={scan}"


def build_report(r: CheckResult) -> str:
    lines = ["Glassbed device check", f"App: {r.app}", f"Time: {r.time}", f"Host: {r.host}",
             "Ports: " + ", ".join(f"{p} {r.ports.get(p, '?')}" for p in PORTS)]
    if r.mdns:
        for type_, port, txt in r.mdns:
            extra = "".join(f' {k}="{txt[k]}"' for k in TXT_KEYS if k in txt)
            lines.append(f"mDNS: {type_} port {port}{extra}")
    else:
        lines.append("mDNS: no services from this host")
    lines.append(f"IPP: {r.ipp}")
    lines.append(f"eSCL: {r.escl}")
    lines.append(f"WSD: ok types={r.wsd_types} xaddrs={r.wsd_xaddrs}" if r.wsd_types or r.wsd_xaddrs
                 else "WSD: no answer")
    lines.append(f"Verdict: {verdict(r)}")
    return "\n".join(lines)


def parse_probe_match(xml: str) -> tuple[str, str] | None:
    """WS-Discovery ProbeMatch → (Types, XAddrs), namespace prefixes ignored."""
    if "ProbeMatch" not in xml:
        return None

    def text(tag: str) -> str:
        m = re.search(rf"<(?:\w+:)?{tag}\b[^>]*>(.*?)</(?:\w+:)?{tag}>", xml, re.S)
        return " ".join(m.group(1).split()) if m else ""

    return text("Types"), text("XAddrs")


def _error(e: BaseException) -> str:
    if isinstance(e, NotLocalNetwork):
        return f"not a local address ({e.host})"
    if isinstance(e, urllib.error.HTTPError):
        return f"HTTP {e.code}"
    reason = getattr(e, "reason", None) or e
    if isinstance(reason, (socket.timeout, TimeoutError)):
        return "timeout"
    if isinstance(reason, ConnectionRefusedError):
        return "connection refused"
    return str(reason) or type(e).__name__


# --------------------------------------------------------------------------- network parts
def check_port(host: str, port: int, timeout: float = 2.0) -> str:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return "open"
    except ConnectionRefusedError:
        return "closed"
    except OSError as e:
        return "timeout" if isinstance(e, (socket.timeout, TimeoutError)) else "closed"


def browse_mdns(host: str, seconds: float = 4.0) -> list[tuple[str, int, dict[str, str]]]:
    try:
        from zeroconf import ServiceBrowser, Zeroconf
    except ImportError:
        return []
    found: dict[tuple[str, int], dict[str, str]] = {}

    class Listener:
        def add_service(self, zc, type_, name):
            info = zc.get_service_info(type_, name, timeout=2000)
            if not info or not any(len(a) == 4 and socket.inet_ntoa(a) == host for a in info.addresses):
                return
            txt = {k.decode(errors="ignore"): (v or b"").decode(errors="ignore")
                   for k, v in (info.properties or {}).items()}
            found[(type_.removesuffix(".local."), info.port)] = txt

        def update_service(self, *args):
            pass

        def remove_service(self, *args):
            pass

    zc = Zeroconf()
    try:
        ServiceBrowser(zc, [f"{t}.local." for t in MDNS_TYPES], Listener())
        time.sleep(seconds)
    finally:
        zc.close()
    return [(t, p, txt) for (t, p), txt in sorted(found.items())]


def check_ipp(host: str, rp: str | None = None) -> tuple[bool, str]:
    paths = ([rp.strip("/")] if rp else []) + [p for p in IPP_PATHS if p != (rp or "").strip("/")]
    last = "no answer"
    for path in paths:
        uri = f"ipp://{host}:631/{path}"
        try:
            info = IppPrinter(uri, timeout=4).get_info()
        except Exception as e:  # noqa: BLE001 - every failure goes into the report
            last = _error(e)
            if last in ("connection refused", "timeout"):
                break                                    # no other path will answer either
            continue
        urf = ",".join(info.raw.get("urf-supported", []))
        return True, (f'ok {uri} make-and-model="{info.make_and_model}" formats={",".join(info.formats) or "none"}'
                      f" urf={urf or 'none'} state={info.state}")
    return False, last


def check_escl(host: str, rs: str | None = None, port: int = 80) -> tuple[bool, str]:
    paths = ([rs.strip("/")] if rs else []) + (["eSCL"] if (rs or "").strip("/") != "eSCL" else [])
    last = "no answer"
    for path in paths:
        url = f"http://{host}:{port}/{path}/ScannerCapabilities"
        try:
            with open_local(urllib.request.Request(url), 4) as resp:
                caps = parse_capabilities(resp.read())
        except Exception as e:  # noqa: BLE001
            last = _error(e)
            continue
        if not caps.sources:
            last = "answer without a scan source"
            continue
        return True, f"ok {url} version={caps.version} sources={','.join(caps.sources)}"
    return False, last


def _probe_message() -> bytes:
    return (
        '<?xml version="1.0" encoding="utf-8"?>'
        '<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope" '
        'xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing" '
        'xmlns:wsd="http://schemas.xmlsoap.org/ws/2005/04/discovery">'
        "<soap:Header>"
        "<wsa:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</wsa:To>"
        "<wsa:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</wsa:Action>"
        f"<wsa:MessageID>urn:uuid:{uuid.uuid4()}</wsa:MessageID>"
        "</soap:Header><soap:Body><wsd:Probe/></soap:Body></soap:Envelope>"
    ).encode()


def probe_wsd(host: str, seconds: float = 3.0) -> tuple[str, str] | None:
    """WS-Discovery Probe, unicast to the host and multicast; the answer that comes from the host."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    try:
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, struct.pack("b", 1))
        sock.bind(("", 0))
        msg = _probe_message()
        for target in ((host, WSD_ADDR[1]), WSD_ADDR):
            try:
                sock.sendto(msg, target)
            except OSError:
                pass
        end = time.monotonic() + seconds
        while (left := end - time.monotonic()) > 0:
            sock.settimeout(left)
            try:
                data, (addr, _port) = sock.recvfrom(65535)
            except (socket.timeout, TimeoutError):
                break
            if addr == host and (match := parse_probe_match(data.decode("utf-8", "replace"))):
                return match
    finally:
        sock.close()
    return None


def run_check(host: str) -> CheckResult:
    """All checks, in parallel where possible (about 6–10 seconds). Only for local hosts."""
    host = host.strip()
    check_host(host)                    # NotLocalNetwork: nothing is sent at all
    r = CheckResult(host=host, time=datetime.now(timezone.utc).isoformat(timespec="seconds"))
    with concurrent.futures.ThreadPoolExecutor(max_workers=10) as pool:
        ports = {p: pool.submit(check_port, host, p) for p in PORTS}
        mdns = pool.submit(browse_mdns, host)
        wsd = pool.submit(probe_wsd, host)
        r.ports = {p: f.result() for p, f in ports.items()}
        r.mdns = mdns.result()
        txt = {t: (port, props) for t, port, props in r.mdns}
        rp = txt.get("_ipp._tcp", (0, {}))[1].get("rp")
        uscan = txt.get("_uscan._tcp")
        ipp = pool.submit(check_ipp, host, rp)
        escl = pool.submit(check_escl, host, uscan[1].get("rs") if uscan else None, uscan[0] if uscan else 80)
        r.ipp_ok, r.ipp = ipp.result()
        r.escl_ok, r.escl = escl.result()
        if (match := wsd.result()) is not None:
            r.wsd_types, r.wsd_xaddrs = match
    return r
