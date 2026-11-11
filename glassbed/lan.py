"""Only devices on the local network: the address check before every connection to a device.

The same rules as the Android app (mobile/lib/core/lan.dart): private IPv4 (10/8, 172.16/12,
192.168/16), link-local 169.254/16, IPv6 unique-local fc00::/7 and link-local fe80::/10
(also IPv4-mapped ::ffff:a.b.c.d), and names ending in ".local". Everything else – public
addresses, loopback, other host names – is refused before any connection is made, so a typo,
a crafted Bonjour answer or an HTTP redirect can never make Glassbed talk to the internet.
"""
from __future__ import annotations

import ipaddress
from urllib.parse import urlsplit

_V4 = [ipaddress.ip_network(n) for n in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16")]
_V6 = [ipaddress.ip_network(n) for n in ("fc00::/7", "fe80::/10")]


class NotLocalNetwork(Exception):
    """Raised instead of connecting to a host outside the local network."""

    def __init__(self, host: str):
        super().__init__(f"{host} is not on the local network")
        self.host = host


def is_local_host(host: str) -> bool:
    h = (host or "").strip().lower()
    if h.startswith("[") and h.endswith("]"):
        h = h[1:-1]
    h = h.split("%", 1)[0].rstrip(".")                # IPv6 zone id (fe80::1%eth0), trailing dot
    if not h:
        return False
    try:
        addr = ipaddress.ip_address(h)
    except ValueError:
        # a name: only mDNS names are resolved on the local link by definition
        return h.endswith(".local") and len(h) > len(".local")
    if isinstance(addr, ipaddress.IPv6Address) and addr.ipv4_mapped is not None:
        addr = addr.ipv4_mapped
    nets = _V4 if isinstance(addr, ipaddress.IPv4Address) else _V6
    return any(addr in n for n in nets)


def check_host(host: str) -> None:
    if not is_local_host(host):
        raise NotLocalNetwork(host)


def check_url(url: str) -> None:
    """Refuse any URL whose host is not on the local network (also used for every redirect)."""
    check_host(urlsplit(url).hostname or "")
