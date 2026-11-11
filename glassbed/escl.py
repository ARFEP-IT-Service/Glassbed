"""Minimal eSCL (Apple AirScan / Mopria scan) client.

eSCL is a plain HTTP + XML protocol supported by most network scanners
made since ~2014, including the HP Color Laser MFP 178/179 series.
"""
from __future__ import annotations

import threading
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from io import BytesIO
from typing import Callable
from urllib.parse import urljoin

from PIL import Image

from .lan import check_url

NS = {
    "scan": "http://schemas.hp.com/imaging/escl/2011/05/03",
    "pwg": "http://www.pwg.org/schemas/2010/12/sm",
}

# Scan regions are expressed in 1/300 inch.
PAPER_SIZES = {
    "A4": (2480, 3507),
    "Letter": (2550, 3300),
    "A5": (1748, 2480),
}


class ScannerError(Exception):
    pass


class ScannerBusy(ScannerError):
    pass


class FeederEmpty(ScannerError):
    pass


class ScanCancelled(ScannerError):
    pass


@dataclass
class SourceCaps:
    max_width: int
    max_height: int
    resolutions: list[int]
    color_modes: list[str]


@dataclass
class ScannerCaps:
    make_and_model: str = ""
    version: str = "2.0"
    sources: dict[str, SourceCaps] = field(default_factory=dict)  # "Platen" / "Feeder"


@dataclass
class ScanSettings:
    source: str = "Platen"          # "Platen" or "Feeder"
    color_mode: str = "RGB24"       # "RGB24", "Grayscale8", "BlackAndWhite1"
    resolution: int = 300
    paper: str = "A4"               # key of PAPER_SIZES or "Max"
    intent: str = "Document"        # "Document", "Photo", "TextAndGraphic"


@dataclass
class ScannerStatus:
    state: str = "Unknown"          # "Idle", "Processing", "Stopped", ...
    adf_state: str = ""             # e.g. "ScannerAdfLoaded", "ScannerAdfEmpty"

    @property
    def adf_loaded(self) -> bool:
        return self.adf_state == "ScannerAdfLoaded"


def _text(el: ET.Element | None, path: str, default: str = "") -> str:
    if el is None:
        return default
    found = el.find(path, NS)
    return found.text.strip() if found is not None and found.text else default


def parse_capabilities(xml_bytes: bytes) -> ScannerCaps:
    root = ET.fromstring(xml_bytes)
    caps = ScannerCaps(
        make_and_model=_text(root, "pwg:MakeAndModel"),
        version=_text(root, "pwg:Version", "2.0"),
    )
    for tag, name in (("scan:Platen/scan:PlatenInputCaps", "Platen"),
                      ("scan:Adf/scan:AdfSimplexInputCaps", "Feeder")):
        node = root.find(tag, NS)
        if node is None:
            continue
        resolutions = sorted({
            int(r.text) for r in node.iterfind(".//scan:DiscreteResolution/scan:XResolution", NS)
            if r.text
        })
        modes = [m.text for m in node.iterfind(".//scan:ColorModes/scan:ColorMode", NS) if m.text]
        caps.sources[name] = SourceCaps(
            max_width=int(_text(node, "scan:MaxWidth", "2550")),
            max_height=int(_text(node, "scan:MaxHeight", "3507")),
            resolutions=resolutions or [300],
            color_modes=list(dict.fromkeys(modes)) or ["RGB24"],
        )
    return caps


def parse_status(xml_bytes: bytes) -> ScannerStatus:
    root = ET.fromstring(xml_bytes)
    return ScannerStatus(
        state=_text(root, "pwg:State", "Unknown"),
        adf_state=_text(root, "scan:AdfState"),
    )


def build_scan_settings(settings: ScanSettings, caps: ScannerCaps) -> bytes:
    src = caps.sources.get(settings.source)
    if settings.paper in PAPER_SIZES:
        width, height = PAPER_SIZES[settings.paper]
    else:
        width, height = (src.max_width, src.max_height) if src else (2550, 3507)
    if src:
        width, height = min(width, src.max_width), min(height, src.max_height)
    version = caps.version or "2.0"
    # 1-bit JPEG does not exist; many devices (e.g. HP 178/179) fail the job.
    # Scan in grayscale and threshold on the client instead.
    color_mode = "Grayscale8" if settings.color_mode == "BlackAndWhite1" else settings.color_mode
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<scan:ScanSettings xmlns:scan="{NS['scan']}" xmlns:pwg="{NS['pwg']}">
  <pwg:Version>{version}</pwg:Version>
  <scan:Intent>{settings.intent}</scan:Intent>
  <pwg:ScanRegions>
    <pwg:ScanRegion>
      <pwg:ContentRegionUnits>escl:ThreeHundredthsOfInches</pwg:ContentRegionUnits>
      <pwg:XOffset>0</pwg:XOffset>
      <pwg:YOffset>0</pwg:YOffset>
      <pwg:Width>{width}</pwg:Width>
      <pwg:Height>{height}</pwg:Height>
    </pwg:ScanRegion>
  </pwg:ScanRegions>
  <pwg:InputSource>{settings.source}</pwg:InputSource>
  <scan:ColorMode>{color_mode}</scan:ColorMode>
  <pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat>
  <scan:DocumentFormatExt>image/jpeg</scan:DocumentFormatExt>
  <scan:XResolution>{settings.resolution}</scan:XResolution>
  <scan:YResolution>{settings.resolution}</scan:YResolution>
</scan:ScanSettings>
""".encode("utf-8")


class LocalRedirects(urllib.request.HTTPRedirectHandler):
    """Follow an HTTP redirect only to the local network – every hop is checked (at most 5)."""

    max_redirections = 5

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        check_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


_OPENER = urllib.request.build_opener(LocalRedirects())


def open_local(req: urllib.request.Request, timeout: float):
    """urlopen for a device on the local network; a non-local URL raises NotLocalNetwork."""
    check_url(req.full_url)
    return _OPENER.open(req, timeout=timeout)


class EsclScanner:
    def __init__(self, base_url: str, timeout: float = 15.0):
        # base_url like "http://192.168.1.20/eSCL/"
        self.base_url = base_url if base_url.endswith("/") else base_url + "/"
        self.timeout = timeout
        self._caps: ScannerCaps | None = None

    # -- HTTP helpers -------------------------------------------------------
    def _request(self, method: str, url: str, data: bytes | None = None,
                 timeout: float | None = None):
        headers = {"Content-Type": "text/xml"} if data is not None else {}
        req = urllib.request.Request(url, data=data, method=method, headers=headers)
        return open_local(req, timeout or self.timeout)

    # -- API ----------------------------------------------------------------
    def capabilities(self, refresh: bool = False) -> ScannerCaps:
        if self._caps is None or refresh:
            with self._request("GET", self.base_url + "ScannerCapabilities") as r:
                self._caps = parse_capabilities(r.read())
        return self._caps

    def status(self) -> ScannerStatus:
        with self._request("GET", self.base_url + "ScannerStatus") as r:
            return parse_status(r.read())

    def _create_job(self, body: bytes) -> str:
        deadline = time.monotonic() + 20
        while True:
            try:
                with self._request("POST", self.base_url + "ScanJobs", body) as r:
                    location = r.headers.get("Location")
                    if not location:
                        raise ScannerError("Scanner did not return a job location")
                    return urljoin(self.base_url, location)
            except urllib.error.HTTPError as e:
                if e.code in (503, 409) and time.monotonic() < deadline:
                    time.sleep(1.0)
                    continue
                if e.code in (503, 409):
                    raise ScannerBusy("Scanner is busy") from e
                raise ScannerError(f"Scanner rejected the scan job (HTTP {e.code})") from e

    def cancel(self, job_url: str) -> None:
        try:
            self._request("DELETE", job_url, timeout=5).close()
        except Exception:
            pass

    def scan(self, settings: ScanSettings,
             on_page: Callable[[Image.Image], None] | None = None,
             cancel: threading.Event | None = None) -> list[Image.Image]:
        """Run a scan job and return all pages (one for the glass, N for the feeder)."""
        caps = self.capabilities()
        if settings.source == "Feeder":
            if "Feeder" not in caps.sources:
                raise ScannerError("This scanner has no document feeder")
            st = self.status()
            if st.adf_state and not st.adf_loaded:
                raise FeederEmpty("The document feeder is empty")

        job_url = self._create_job(build_scan_settings(settings, caps))
        next_doc = job_url.rstrip("/") + "/NextDocument"
        pages: list[Image.Image] = []
        try:
            while True:
                if cancel is not None and cancel.is_set():
                    raise ScanCancelled()
                data = self._fetch_next(next_doc, cancel)
                if data is None:
                    break
                img = Image.open(BytesIO(data))
                img.load()
                if settings.color_mode == "BlackAndWhite1" and img.mode != "1":
                    img = img.convert("L").point(lambda v: 255 if v > 160 else 0).convert("1")
                elif settings.color_mode == "Grayscale8" and img.mode != "L":
                    img = img.convert("L")
                elif settings.color_mode == "RGB24" and img.mode != "RGB":
                    img = img.convert("RGB")
                img.info["dpi"] = (settings.resolution, settings.resolution)
                pages.append(img)
                if on_page:
                    on_page(img)
        except ScanCancelled:
            self.cancel(job_url)
            raise
        if not pages:
            raise ScannerError("The scanner returned no pages")
        return pages

    def _fetch_next(self, url: str, cancel: threading.Event | None) -> bytes | None:
        deadline = time.monotonic() + 180
        while True:
            if cancel is not None and cancel.is_set():
                raise ScanCancelled()
            try:
                with self._request("GET", url, timeout=120) as r:
                    return r.read()
            except urllib.error.HTTPError as e:
                if e.code in (404, 410):   # no more pages / job gone
                    return None
                if e.code == 503 and time.monotonic() < deadline:
                    time.sleep(0.5)        # still scanning
                    continue
                raise ScannerError(f"Error while fetching the scan (HTTP {e.code})") from e
