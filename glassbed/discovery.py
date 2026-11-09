"""Find AirScan/AirPrint devices on the local network via mDNS (Bonjour)."""
from __future__ import annotations

import socket
import time
from dataclasses import dataclass

SERVICES = ["_uscan._tcp.local.", "_ipp._tcp.local.", "_ipps._tcp.local."]


@dataclass
class Device:
    name: str
    host: str
    escl_url: str
    ipp_uri: str
    # True: announced a scanner (_uscan), False: printer only, None: not known (entered by hand).
    # Only a hint for the list – whether the device really scans is decided when it is selected.
    scanner: bool | None = None

    @classmethod
    def from_host(cls, host: str, name: str | None = None) -> "Device":
        host = host.strip()
        return cls(
            name=name or host,
            host=host,
            escl_url=f"http://{host}/eSCL/",
            ipp_uri=f"ipp://{host}:631/ipp/print",
        )


def add_service(found: dict[str, dict], type_: str, name: str, host: str, port: int,
                props: dict[str, str]) -> None:
    """Record one resolved mDNS service in ``found`` (one entry per host)."""
    entry = found.setdefault(host, {"name": name.split("._")[0]})
    if type_.startswith("_uscan"):
        rs = props.get("rs", "eSCL").strip("/")
        entry["escl"] = f"http://{host}:{port}/{rs}/"
        if props.get("ty"):
            entry["name"] = props["ty"]
            entry["name_from_scanner"] = True
        entry["scanner"] = True
    elif type_.startswith("_ipps"):
        # IPP over TLS; Glassbed talks plain IPP, which these printers also accept on port 631
        rp = props.get("rp", "ipp/print").strip("/")
        entry.setdefault("ipp", f"ipp://{host}:631/{rp}")
        if props.get("ty") and not entry.get("name_from_scanner"):
            entry["name"] = props["ty"]
    else:
        rp = props.get("rp", "ipp/print").strip("/")
        entry["ipp"] = f"ipp://{host}:{port}/{rp}"
        if props.get("ty") and not entry.get("name_from_scanner"):
            entry["name"] = props["ty"]


def devices_from(found: dict[str, dict]) -> list[Device]:
    devices = []
    for host, e in found.items():
        d = Device.from_host(host, e.get("name"))
        d.escl_url = e.get("escl", d.escl_url)
        d.ipp_uri = e.get("ipp", d.ipp_uri)
        d.scanner = bool(e.get("scanner"))
        devices.append(d)
    return sorted(devices, key=lambda d: d.name.lower())


def discover(timeout: float = 3.0) -> list[Device]:
    """Browse for _uscan._tcp (eSCL), _ipp._tcp and _ipps._tcp (IPP) services.

    Returns one Device per host. Requires the optional `zeroconf` package;
    returns an empty list when it is missing.
    """
    try:
        from zeroconf import ServiceBrowser, Zeroconf
    except ImportError:
        return []

    found: dict[str, dict] = {}

    class Listener:
        def add_service(self, zc, type_, name):
            info = zc.get_service_info(type_, name, timeout=2000)
            if not info or not info.addresses:
                return
            host = socket.inet_ntoa(info.addresses[0]) if len(info.addresses[0]) == 4 else None
            if not host:
                return
            props = {k.decode(errors="ignore"): (v or b"").decode(errors="ignore")
                     for k, v in (info.properties or {}).items()}
            add_service(found, type_, name, host, info.port, props)

        def update_service(self, *args):
            pass

        def remove_service(self, *args):
            pass

    zc = Zeroconf()
    try:
        listener = Listener()
        ServiceBrowser(zc, SERVICES, listener)
        time.sleep(timeout)
    finally:
        zc.close()
    return devices_from(found)
