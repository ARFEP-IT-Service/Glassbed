"""Optional update check against the project's GitHub releases – off unless the user agrees.

Nothing here runs on its own: the GUI calls ``fetch_latest`` only when the user switched the
check on (at most once a day) or clicked "Check now". The only connection is one HTTPS request
to the GitHub API (``ALLOWED_HOSTS``). Glassbed downloads and starts nothing itself: "Update"
opens the setup's download link or the release page in the browser.
"""
from __future__ import annotations

import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urlsplit

from . import __version__

REPO = "ARFEP-IT-Service/Glassbed"
# the list of releases: Windows and Android share this repository, so "latest" may be an Android
# release (tag android-v…); only tags vX.Y.Z belong to the Windows app
API_URL = f"https://api.github.com/repos/{REPO}/releases?per_page=50"
WINDOWS_TAG = re.compile(r"v(\d+)\.(\d+)\.(\d+)")
RELEASES_URL = f"https://github.com/{REPO}/releases"
DOWNLOAD_PREFIX = f"https://github.com/{REPO}/releases/download/"
# the update check talks to the GitHub API only
ALLOWED_HOSTS = frozenset({"api.github.com"})
TIMEOUT = 10
CHECK_INTERVAL = timedelta(hours=24)
USER_AGENT = f"Glassbed/{__version__}"
UNINSTALL_KEY = r"Software\Microsoft\Windows\CurrentVersion\Uninstall\Glassbed"


class UpdateError(Exception):
    """Anything that stops a check; the message is shown after "Check now"."""


# --------------------------------------------------------------------------- settings
@dataclass(frozen=True)
class Config:
    api_url: str = API_URL
    download_prefix: str = DOWNLOAD_PREFIX
    allowed_hosts: frozenset = ALLOWED_HOSTS
    cafile: str | None = None


def config() -> Config:
    """The real endpoints – or, only in source runs and test builds, a local test release.

    ``glassbed._update_testing`` is left out of the release build (build.ps1), so its
    environment variables have no effect there.
    """
    try:
        from . import _update_testing
    except ImportError:
        return Config()
    return _update_testing.config(Config) or Config()


# --------------------------------------------------------------------------- versions
def parse_version(text: str) -> tuple[int, int, int] | None:
    """"0.3.0" or "v0.3.0" → (0, 3, 0); anything else (pre-releases, "1.2") → None."""
    m = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)", (text or "").strip())
    return tuple(int(x) for x in m.groups()) if m else None


def is_newer(remote: str, current: str = __version__) -> bool:
    r, c = parse_version(remote), parse_version(current)
    return r is not None and c is not None and r > c


def check_due(last_check: str | None, now: datetime | None = None) -> bool:
    """At most one automatic check per 24 hours (a clock set back also allows a new check)."""
    now = now or datetime.now(timezone.utc)
    try:
        last = datetime.fromisoformat(str(last_check))
    except (TypeError, ValueError):
        return True
    if last.tzinfo is None:
        last = last.replace(tzinfo=timezone.utc)
    return not (timedelta(0) <= now - last < CHECK_INTERVAL)


def stamp(now: datetime | None = None) -> str:
    return (now or datetime.now(timezone.utc)).isoformat(timespec="seconds")


@dataclass(frozen=True)
class Release:
    version: str
    page_url: str
    setup_url: str | None = None           # direct download link of Glassbed-X-setup.exe


def should_notify(release: Release | None, current: str = __version__, skipped: str = "") -> bool:
    return release is not None and is_newer(release.version, current) and release.version != skipped


def parse_release(data: dict, cfg: Config | None = None) -> Release | None:
    """The GitHub API answer → Release; drafts, pre-releases and odd tags are ignored."""
    cfg = cfg or config()
    if not isinstance(data, dict) or data.get("draft") or data.get("prerelease"):
        return None
    ver = parse_version(str(data.get("tag_name", "")))
    if ver is None:
        return None
    version = "%d.%d.%d" % ver
    page = str(data.get("html_url") or "")
    if not page.startswith(RELEASES_URL + "/"):
        page = RELEASES_URL
    setup_name = f"Glassbed-{version}-setup.exe"
    urls = {str(a.get("name")): str(a.get("browser_download_url") or "")
            for a in data.get("assets") or [] if isinstance(a, dict)}
    # exactly the setup of this release in this repository – anything else: release page only
    expected = f"{cfg.download_prefix}v{version}/{setup_name}"
    setup_url = expected if urls.get(setup_name) == expected else None
    return Release(version, page, setup_url)


# --------------------------------------------------------------------------- network
def check_url(url: str, cfg: Config) -> None:
    parts = urlsplit(url)
    if parts.scheme != "https" or (parts.hostname or "").lower() not in cfg.allowed_hosts:
        raise UpdateError(f"Refusing to connect to {parts.scheme}://{parts.hostname}")


class _CheckedRedirects(urllib.request.HTTPRedirectHandler):
    def __init__(self, cfg: Config):
        super().__init__()
        self.cfg = cfg

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        check_url(newurl, self.cfg)             # any other host or plain HTTP: stop here
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def _open(url: str, cfg: Config, accept: str = "*/*"):
    check_url(url, cfg)
    ctx = ssl.create_default_context(cafile=cfg.cafile) if cfg.cafile else ssl.create_default_context()
    opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx), _CheckedRedirects(cfg))
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": accept})
    try:
        return opener.open(req, timeout=TIMEOUT)
    except urllib.error.HTTPError as e:
        raise UpdateError(f"HTTP {e.code} from {urlsplit(url).hostname}") from None
    except (urllib.error.URLError, OSError) as e:
        reason = getattr(e, "reason", e)
        if isinstance(reason, UpdateError):
            raise reason from None
        raise UpdateError(str(reason)) from None


def select_release(releases: list, cfg: Config | None = None) -> Release | None:
    """The newest Windows release in GitHub's release list.

    Only published releases (no drafts, no pre-releases) whose tag is exactly vX.Y.Z count;
    Android tags (android-v…) and anything else are ignored.
    """
    best = None
    for item in releases if isinstance(releases, list) else []:
        if not isinstance(item, dict) or item.get("draft") or item.get("prerelease"):
            continue
        m = WINDOWS_TAG.fullmatch(str(item.get("tag_name", "")))
        if m is None:
            continue
        version = tuple(int(x) for x in m.groups())
        if best is None or version > best[0]:
            best = (version, item)
    return parse_release(best[1], cfg) if best else None


def fetch_latest(cfg: Config | None = None) -> Release | None:
    """Ask GitHub for the release list and pick the newest Windows release (one HTTPS request)."""
    cfg = cfg or config()
    with _open(cfg.api_url, cfg, "application/vnd.github+json") as resp:
        try:
            data = json.loads(resp.read(4 * 1024 * 1024).decode("utf-8"))
        except ValueError:
            raise UpdateError("Unexpected answer from GitHub") from None
    if not isinstance(data, list):
        raise UpdateError("Unexpected answer from GitHub")
    return select_release(data, cfg)


# --------------------------------------------------------------------------- installation
def install_kind(exe: str | None = None, registry=None) -> str:
    """"installer" (installed with the setup), "portable", "source" or "unsupported" (not Windows)."""
    if sys.platform != "win32":
        return "unsupported"
    if not getattr(sys, "frozen", False) and exe is None:
        return "source"
    folder = Path(exe or sys.executable).resolve().parent
    if not (folder / "uninstall.exe").is_file():
        return "portable"
    try:
        if registry is None:
            import winreg as registry
        with registry.OpenKey(registry.HKEY_CURRENT_USER, UNINSTALL_KEY) as key:
            location, _ = registry.QueryValueEx(key, "InstallLocation")
    except OSError:
        return "portable"
    same = os.path.normcase(os.path.abspath(str(location))) == os.path.normcase(str(folder))
    return "installer" if same else "portable"
