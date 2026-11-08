"""Find AirScan/AirPrint devices on the local network via mDNS (Bonjour)."""
from __future__ import annotations

import socket
import time
from dataclasses import dataclass


@dataclass
class Device:
    name: str
    host: str
    escl_url: str
    ipp_uri: str

    @classmethod
    def from_host(cls, host: str, name: str | None = None) -> "Device":
        host = host.strip()
        return cls(
            name=name or host,
            host=host,
            escl_url=f"http://{host}/eSCL/",
            ipp_uri=f"ipp://{host}:631/ipp/print",
        )


def discover(timeout: float = 3.0) -> list[Device]:
    """Browse for _uscan._tcp (eSCL) and _ipp._tcp (IPP) services.

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
            entry = found.setdefault(host, {"name": name.split("._")[0]})
            if type_.startswith("_uscan"):
                rs = props.get("rs", "eSCL").strip("/")
                entry["escl"] = f"http://{host}:{info.port}/{rs}/"
                entry["name"] = props.get("ty") or entry["name"]
            else:
                rp = props.get("rp", "ipp/print").strip("/")
                entry["ipp"] = f"ipp://{host}:{info.port}/{rp}"
                entry.setdefault("name", props.get("ty") or entry["name"])

        def update_service(self, *args):
            pass

        def remove_service(self, *args):
            pass

    zc = Zeroconf()
    try:
        listener = Listener()
        ServiceBrowser(zc, ["_uscan._tcp.local.", "_ipp._tcp.local."], listener)
        time.sleep(timeout)
    finally:
        zc.close()

    devices = []
    for host, e in found.items():
        d = Device.from_host(host, e.get("name"))
        d.escl_url = e.get("escl", d.escl_url)
        d.ipp_uri = e.get("ipp", d.ipp_uri)
        devices.append(d)
    return sorted(devices, key=lambda d: d.name.lower())
