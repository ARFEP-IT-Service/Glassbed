"""Optional update check against the project's GitHub releases – off unless the user agrees.

Nothing here runs on its own: the GUI calls ``fetch_latest`` only when the user switched the
check on (at most once a day) or clicked "Check now": one HTTPS request to the GitHub API
(``ALLOWED_HOSTS``). Only when the user clicks "Update" in the installed version, the setup and its
``.sha256`` file are downloaded – over HTTPS from the release download URL of this repository and
GitHub's file hosts only (``DOWNLOAD_HOSTS``) – and the setup is started only if its SHA-256 matches.
The verified setup is marked as downloaded from the internet (Zone.Identifier, like a browser
download) and opened through the Windows shell, so SmartScreen checks it as usual; it then runs
normally (visible). Nothing is installed silently.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import ssl
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
# the list of releases: Windows and Android share this repository, so "latest" may be an Android
# release (tag android-v…); only tags vX.Y.Z belong to the Windows app
API_URL = f"https://api.github.com/repos/{REPO}/releases?per_page=50"
WINDOWS_TAG = re.compile(r"v(\d+)\.(\d+)\.(\d+)")
RELEASES_URL = f"https://github.com/{REPO}/releases"
DOWNLOAD_PREFIX = f"https://github.com/{REPO}/releases/download/"
# the update check talks to the GitHub API only
ALLOWED_HOSTS = frozenset({"api.github.com"})
# downloads: GitHub answers a release download with a redirect to one of its file hosts
DOWNLOAD_HOSTS = frozenset({"github.com", "release-assets.githubusercontent.com",
                            "objects.githubusercontent.com"})
MAX_DOWNLOAD = 400 * 1024 * 1024
TEMP_PARENT = "Glassbed-update"
TIMEOUT = 10
CHECK_INTERVAL = timedelta(hours=24)
USER_AGENT = f"Glassbed/{__version__}"
UNINSTALL_KEY = r"Software\Microsoft\Windows\CurrentVersion\Uninstall\Glassbed"


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
    download_hosts: frozenset = DOWNLOAD_HOSTS
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
    sha256_url: str | None = None          # …and of Glassbed-X-setup.exe.sha256

    @property
    def setup_name(self) -> str:
        return f"Glassbed-{self.version}-setup.exe"


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
    sha_url = expected + ".sha256" if setup_url and urls.get(setup_name + ".sha256") == expected + ".sha256"         else None
    return Release(version, page, setup_url, sha_url)


# --------------------------------------------------------------------------- network
def check_url(url: str, hosts: frozenset) -> None:
    parts = urlsplit(url)
    if parts.scheme != "https" or (parts.hostname or "").lower() not in hosts:
        raise UpdateError(f"Refusing to connect to {parts.scheme}://{parts.hostname}")


class _CheckedRedirects(urllib.request.HTTPRedirectHandler):
    def __init__(self, hosts: frozenset):
        super().__init__()
        self.hosts = hosts

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        check_url(newurl, self.hosts)           # any other host or plain HTTP: stop here
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def _open(url: str, cfg: Config, accept: str = "*/*", hosts: frozenset | None = None):
    hosts = cfg.allowed_hosts if hosts is None else hosts
    check_url(url, hosts)
    ctx = ssl.create_default_context(cafile=cfg.cafile) if cfg.cafile else ssl.create_default_context()
    opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx), _CheckedRedirects(hosts))
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


# --------------------------------------------------------------------------- download
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
    """Download the setup and verify it against the published SHA-256.

    On any problem (also when cancelled) the partial file is deleted and UpdateError is raised.
    """
    cfg = cfg or config()
    expected_url = f"{cfg.download_prefix}v{release.version}/{release.setup_name}"
    if release.setup_url != expected_url or release.sha256_url != expected_url + ".sha256":
        raise UpdateError("This release has no installer to download")
    with _open(release.sha256_url, cfg, hosts=cfg.download_hosts) as resp:
        expected = parse_sha256(resp.read(64 * 1024).decode("utf-8", "replace"), release.setup_name)
    target = folder / release.setup_name
    digest = hashlib.sha256()
    try:
        with _open(release.setup_url, cfg, hosts=cfg.download_hosts) as resp, open(target, "wb") as out:
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
        mark_from_internet(target, release.setup_url, release.page_url)
    except BaseException:
        target.unlink(missing_ok=True)
        raise
    return target


def mark_from_internet(path: Path, host_url: str, referrer_url: str | None = None) -> None:
    """Add the "Mark of the Web" a browser adds (Zone.Identifier stream, ZoneId=3 = internet).

    Windows then treats the setup like any downloaded file: SmartScreen checks it when it is
    opened. If the mark cannot be written, the download is not used.
    """
    if sys.platform != "win32":
        return
    lines = ["[ZoneTransfer]", "ZoneId=3"]
    if referrer_url:
        lines.append(f"ReferrerUrl={referrer_url}")
    lines.append(f"HostUrl={host_url}")
    try:
        with open(f"{path}:Zone.Identifier", "w", encoding="ascii", newline="\r\n") as f:
            f.write("\n".join(lines) + "\n")
    except (OSError, UnicodeError) as e:
        raise UpdateError(f"Could not mark the download as coming from the internet: {e}") from None


def temp_root() -> Path:
    return Path(tempfile.gettempdir()) / TEMP_PARENT


def new_temp_dir() -> Path:
    root = temp_root()
    root.mkdir(exist_ok=True)
    return Path(tempfile.mkdtemp(prefix="dl-", dir=root))


def cleanup_temp() -> None:
    """Remove downloads of earlier updates (a running setup cannot delete itself)."""
    shutil.rmtree(temp_root(), ignore_errors=True)


# --------------------------------------------------------------------------- installation
def install_kind(exe: str | None = None, registry=None) -> str:
    """"installer" (installed with the setup), "portable", "source" or "unsupported" (not Windows)."""
    if sys.platform != "win32":
        return "unsupported"
    if exe is None and registry is None:
        try:
            from . import _update_testing          # source runs and test builds only
        except ImportError:
            pass
        else:
            if kind := _update_testing.install_kind():
                return kind
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
    """Open the downloaded setup through the Windows shell, like a double-click.

    The shell honours the Zone.Identifier mark (SmartScreen); the user sees and confirms every
    step. /FROMAPP only lets the setup wait a few seconds until Glassbed has closed; it installs
    nothing silently and starts Glassbed afterwards only if the user ticks that on the last page.
    The call returns only after SmartScreen's check (seconds), so it runs in a worker thread,
    which the shell needs to be a COM apartment.
    """
    com = None
    if sys.platform == "win32":
        import ctypes
        com = ctypes.windll.ole32
        # COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE, as ShellExecute asks for
        initialized = com.CoInitializeEx(None, 0x2 | 0x4) in (0, 1)
    try:
        os.startfile(str(setup), "open", "/FROMAPP", str(setup.parent))
    finally:
        if com is not None and initialized:
            com.CoUninitialize()
