"""Optional update check against the project's GitHub releases – off unless the user agrees.

Nothing here runs on its own: the GUI calls ``fetch_latest`` only when the user switched the
check on (at most once a day) or clicked "Check now". Downloads are only accepted over HTTPS
from the release download URL of this repository and the hosts GitHub serves release files
from (``ALLOWED_HOSTS``); any other redirect aborts. The setup file is installed only when its
SHA-256 matches the ``.sha256`` file published with it.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import ssl
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Callable
from urllib.parse import urlsplit

from . import __version__

REPO = "ARFEP-IT-Service/Glassbed"
API_URL = f"https://api.github.com/repos/{REPO}/releases/latest"
RELEASES_URL = f"https://github.com/{REPO}/releases"
DOWNLOAD_PREFIX = f"https://github.com/{REPO}/releases/download/"
# GitHub answers release downloads with a redirect to one of its file hosts
ALLOWED_HOSTS = frozenset({"api.github.com", "github.com",
                           "release-assets.githubusercontent.com", "objects.githubusercontent.com"})
TIMEOUT = 10
CHECK_INTERVAL = timedelta(hours=24)
USER_AGENT = f"Glassbed/{__version__}"
TEMP_PARENT = "Glassbed-update"
UNINSTALL_KEY = r"Software\Microsoft\Windows\CurrentVersion\Uninstall\Glassbed"
MAX_DOWNLOAD = 400 * 1024 * 1024


class UpdateError(Exception):
    """Anything that stops a check or a download; the message is shown to the user."""


class Cancelled(UpdateError):
    pass


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
    setup_name: str | None = None
    setup_url: str | None = None
    sha256_url: str | None = None


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
    setup_url, sha_url = urls.get(setup_name), urls.get(setup_name + ".sha256")
    if not (setup_url and sha_url and setup_url.startswith(cfg.download_prefix)
            and sha_url.startswith(cfg.download_prefix)):
        setup_url = sha_url = None              # only the release page can be offered then
    return Release(version, page, setup_name if setup_url else None, setup_url, sha_url)


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


def fetch_latest(cfg: Config | None = None) -> Release | None:
    """Ask GitHub for the newest published release (one HTTPS request)."""
    cfg = cfg or config()
    with _open(cfg.api_url, cfg, "application/vnd.github+json") as resp:
        try:
            data = json.loads(resp.read(1024 * 1024).decode("utf-8"))
        except ValueError:
            raise UpdateError("Unexpected answer from GitHub") from None
    return parse_release(data, cfg)


def parse_sha256(text: str, filename: str) -> str:
    """``<hash>  <name>`` (sha256sum format) or a bare hash → the lowercase hash."""
    for line in text.splitlines():
        parts = line.strip().split()
        if not parts or not re.fullmatch(r"[0-9a-fA-F]{64}", parts[0]):
            continue
        if len(parts) == 1 or parts[-1].lstrip("*") == filename:
            return parts[0].lower()
    raise UpdateError("The checksum file has no SHA-256 for " + filename)


def download(release: Release, folder: Path, progress: Callable[[int, int], None] | None = None,
             cancelled: Callable[[], bool] = lambda: False, cfg: Config | None = None) -> Path:
    """Download the setup file and verify it against the published SHA-256.

    On any problem the partial file is deleted and UpdateError is raised.
    """
    cfg = cfg or config()
    if not (release.setup_url and release.sha256_url and release.setup_name):
        raise UpdateError("This release has no installer")
    for url in (release.setup_url, release.sha256_url):
        if not url.startswith(cfg.download_prefix):
            raise UpdateError("Unexpected download address")
    with _open(release.sha256_url, cfg) as resp:
        expected = parse_sha256(resp.read(64 * 1024).decode("utf-8", "replace"), release.setup_name)
    target = folder / release.setup_name
    digest = hashlib.sha256()
    try:
        with _open(release.setup_url, cfg) as resp, open(target, "wb") as out:
            total = int(resp.headers.get("Content-Length") or 0)
            done = 0
            while chunk := resp.read(256 * 1024):
                if cancelled():
                    raise Cancelled("Cancelled")
                out.write(chunk)
                digest.update(chunk)
                done += len(chunk)
                if done > MAX_DOWNLOAD:
                    raise UpdateError("The download is unexpectedly large")
                if progress:
                    progress(done, total)
        if digest.hexdigest() != expected:
            raise UpdateError("The downloaded file does not match its published SHA-256 checksum. "
                              "It was deleted and nothing was installed.")
    except BaseException:
        target.unlink(missing_ok=True)
        raise
    return target


# --------------------------------------------------------------------------- temp folder
def temp_root() -> Path:
    return Path(tempfile.gettempdir()) / TEMP_PARENT


def new_temp_dir() -> Path:
    root = temp_root()
    root.mkdir(exist_ok=True)
    return Path(tempfile.mkdtemp(prefix="dl-", dir=root))


def cleanup_temp() -> None:
    """Remove downloads of earlier updates (the setup cannot delete itself while it runs)."""
    shutil.rmtree(temp_root(), ignore_errors=True)


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


def start_installer(setup: Path) -> None:
    """Run the setup silently; it waits for Glassbed to exit, updates and starts it again."""
    flags = 0
    if sys.platform == "win32":
        flags = subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP
    subprocess.Popen([str(setup), "/S", "/UPDATE"], cwd=str(setup.parent), close_fds=True,
                     creationflags=flags)
