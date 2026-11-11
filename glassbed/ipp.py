"""Minimal IPP/2.0 client (RFC 8011) – enough to query a printer and send a job."""
from __future__ import annotations

import http.client
import struct
from dataclasses import dataclass, field
from itertools import count
from urllib.parse import urljoin, urlsplit

from .lan import check_host, check_url

# Operation ids
PRINT_JOB = 0x0002
VALIDATE_JOB = 0x0004
GET_PRINTER_ATTRIBUTES = 0x000B

# Delimiter tags
OPERATION_ATTRS = 0x01
JOB_ATTRS = 0x02
END_OF_ATTRS = 0x03

# Value tags
TAG_INTEGER = 0x21
TAG_BOOLEAN = 0x22
TAG_ENUM = 0x23
TAG_RANGE = 0x33
TAG_TEXT = 0x41
TAG_NAME = 0x42
TAG_KEYWORD = 0x44
TAG_URI = 0x45
TAG_CHARSET = 0x47
TAG_LANGUAGE = 0x48
TAG_MIME = 0x49

PRINTER_STATES = {3: "idle", 4: "processing", 5: "stopped"}

_request_ids = count(1)


class IppError(Exception):
    pass


@dataclass
class Marker:
    name: str
    level: int      # 0-100, negative = unknown
    color: str      # "#RRGGBB"


@dataclass
class PrinterInfo:
    make_and_model: str = ""
    state: str = "unknown"
    state_reasons: list[str] = field(default_factory=list)
    markers: list[Marker] = field(default_factory=list)
    formats: list[str] = field(default_factory=list)
    media: list[str] = field(default_factory=list)
    color_modes: list[str] = field(default_factory=list)
    sides: list[str] = field(default_factory=list)
    raw: dict[str, list] = field(default_factory=dict)


def _attr(tag: int, name: str, value) -> bytes:
    if tag in (TAG_INTEGER, TAG_ENUM):
        v = struct.pack(">i", value)
    elif tag == TAG_BOOLEAN:
        v = b"\x01" if value else b"\x00"
    else:
        v = value.encode("utf-8") if isinstance(value, str) else value
    n = name.encode("ascii")
    return bytes([tag]) + struct.pack(">H", len(n)) + n + struct.pack(">H", len(v)) + v


def encode_request(operation: int, printer_uri: str, op_attrs: list[tuple] = (),
                   job_attrs: list[tuple] = (), request_id: int | None = None) -> bytes:
    out = bytearray(struct.pack(">BBHI", 2, 0, operation, request_id or next(_request_ids)))
    out.append(OPERATION_ATTRS)
    out += _attr(TAG_CHARSET, "attributes-charset", "utf-8")
    out += _attr(TAG_LANGUAGE, "attributes-natural-language", "en")
    out += _attr(TAG_URI, "printer-uri", printer_uri)
    for tag, name, value in op_attrs:
        out += _attr(tag, name, value)
    if job_attrs:
        out.append(JOB_ATTRS)
        for tag, name, value in job_attrs:
            out += _attr(tag, name, value)
    out.append(END_OF_ATTRS)
    return bytes(out)


def decode_response(data: bytes) -> tuple[int, dict[str, list]]:
    """Return (status_code, attributes). Groups are flattened; later groups win."""
    if len(data) < 8:
        raise IppError("Truncated IPP response")
    status = struct.unpack(">H", data[2:4])[0]
    attrs: dict[str, list] = {}
    i, name = 8, None
    while i < len(data):
        tag = data[i]
        i += 1
        if tag == END_OF_ATTRS:
            break
        if tag < 0x10:          # group delimiter
            continue
        nlen = struct.unpack(">H", data[i:i + 2])[0]
        i += 2
        if nlen:
            name = data[i:i + nlen].decode("utf-8", "replace")
            attrs[name] = []
        i += nlen
        vlen = struct.unpack(">H", data[i:i + 2])[0]
        i += 2
        raw = data[i:i + vlen]
        i += vlen
        if tag in (TAG_INTEGER, TAG_ENUM) and vlen == 4:
            value = struct.unpack(">i", raw)[0]
        elif tag == TAG_BOOLEAN:
            value = raw == b"\x01"
        elif tag == TAG_RANGE and vlen == 8:
            value = struct.unpack(">ii", raw)
        elif 0x40 <= tag <= 0x4F or tag in (0x35, 0x36):
            value = raw.decode("utf-8", "replace")
        else:
            value = raw
        if name is not None:
            attrs[name].append(value)
    return status, attrs


class IppPrinter:
    def __init__(self, uri: str, timeout: float = 15.0):
        # uri like "ipp://192.168.1.20:631/ipp/print"
        self.uri = uri
        parts = urlsplit(uri)
        self.host = parts.hostname or ""
        self.port = parts.port or 631
        self.path = parts.path or "/ipp/print"
        self.timeout = timeout

    def _post(self, body: bytes, timeout: float | None = None) -> tuple[int, dict]:
        host, port, path = self.host, self.port, self.path
        check_host(host)
        for _hop in range(6):
            conn = http.client.HTTPConnection(host, port, timeout=timeout or self.timeout)
            try:
                conn.request("POST", path, body=body, headers={
                    "Content-Type": "application/ipp",
                    "Content-Length": str(len(body)),
                })
                resp = conn.getresponse()
                payload = resp.read()
                location = resp.getheader("Location")
            finally:
                conn.close()
            if resp.status in (307, 308) and location:
                # a redirect keeps the POST; followed only to the local network
                target = urljoin(f"http://{host}:{port}{path}", location)
                check_url(target)
                parts = urlsplit(target)
                host, port, path = parts.hostname or "", parts.port or 80, parts.path or "/"
                continue
            if resp.status != 200:
                raise IppError(f"Printer answered HTTP {resp.status}")
            return decode_response(payload)
        raise IppError("Too many redirects")

    def get_info(self) -> PrinterInfo:
        status, a = self._post(encode_request(GET_PRINTER_ATTRIBUTES, self.uri))
        if status >= 0x0100:
            raise IppError(f"Get-Printer-Attributes failed (0x{status:04x})")
        names = a.get("marker-names", [])
        levels = a.get("marker-levels", [])
        colors = a.get("marker-colors", [])
        markers = [
            Marker(name=n.split("_S/N_")[0].strip(), level=levels[i] if i < len(levels) else -1,
                   color=colors[i] if i < len(colors) else "#888888")
            for i, n in enumerate(names)
        ]
        state = a.get("printer-state", [0])[0]
        return PrinterInfo(
            make_and_model=(a.get("printer-make-and-model") or [""])[0],
            state=PRINTER_STATES.get(state, "unknown"),
            state_reasons=[r for r in a.get("printer-state-reasons", []) if r != "none"],
            markers=markers,
            formats=a.get("document-format-supported", []),
            media=a.get("media-supported", []),
            color_modes=a.get("print-color-mode-supported", []),
            sides=a.get("sides-supported", []),
            raw=a,
        )

    @staticmethod
    def _job_attrs(copies: int, media: str, color: bool) -> list[tuple]:
        return [
            (TAG_INTEGER, "copies", max(1, copies)),
            (TAG_KEYWORD, "media", media),
            (TAG_KEYWORD, "print-color-mode", "color" if color else "monochrome"),
            (TAG_KEYWORD, "sides", "one-sided"),
        ]

    def validate(self, document_format: str, copies: int = 1,
                 media: str = "iso_a4_210x297mm", color: bool = True) -> None:
        body = encode_request(
            VALIDATE_JOB, self.uri,
            op_attrs=[(TAG_NAME, "requesting-user-name", "Glassbed"),
                      (TAG_MIME, "document-format", document_format)],
            job_attrs=self._job_attrs(copies, media, color),
        )
        status, a = self._post(body)
        if status >= 0x0100:
            msg = (a.get("status-message") or [""])[0]
            raise IppError(f"Printer rejected the job (0x{status:04x}) {msg}".strip())

    def print_document(self, document: bytes, document_format: str, job_name: str,
                       copies: int = 1, media: str = "iso_a4_210x297mm",
                       color: bool = True) -> int:
        header = encode_request(
            PRINT_JOB, self.uri,
            op_attrs=[(TAG_NAME, "requesting-user-name", "Glassbed"),
                      (TAG_NAME, "job-name", job_name[:200]),
                      (TAG_MIME, "document-format", document_format)],
            job_attrs=self._job_attrs(copies, media, color),
        )
        status, a = self._post(header + document, timeout=300)
        if status >= 0x0100:
            msg = (a.get("status-message") or [""])[0]
            raise IppError(f"Print job failed (0x{status:04x}) {msg}".strip())
        return (a.get("job-id") or [0])[0]
