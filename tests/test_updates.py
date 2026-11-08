"""Update check: versions, the daily rule, release parsing, download checks and the one-time question.

No test touches the network or the real registry profile: sockets are guarded, the opener and the
registry are fakes and settings live in an ini file under tmp_path.
"""
import hashlib
import io
import os
import socket
import sys
import time
import urllib.request
from datetime import datetime, timedelta, timezone

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PySide6.QtCore import QCoreApplication, QSettings  # noqa: E402
from PySide6.QtWidgets import QApplication, QMainWindow, QPushButton, QWidget  # noqa: E402

from glassbed import _update_testing, i18n, updates  # noqa: E402
from glassbed.gui import update_ui  # noqa: E402
from glassbed.gui.overlay import ConfirmOverlay  # noqa: E402
from glassbed.gui.update_ui import UpdateController  # noqa: E402

PREFIX = "https://github.com/ARFEP-IT-Service/Glassbed/releases/download/"
SETUP = "Glassbed-0.3.1-setup.exe"


# -- guards -------------------------------------------------------------------
@pytest.fixture(autouse=True)
def no_network(monkeypatch):
    """Every connection attempt is recorded and refused; none may happen."""
    attempts = []

    def refuse(*args, **kwargs):
        attempts.append(args)
        raise OSError("network disabled in tests")

    monkeypatch.setattr(socket.socket, "connect", refuse)
    monkeypatch.setattr(socket.socket, "connect_ex", refuse)
    monkeypatch.setattr(socket, "create_connection", refuse)
    monkeypatch.setattr(socket, "getaddrinfo", refuse)
    yield attempts
    assert attempts == [], f"network was attempted: {attempts}"


@pytest.fixture(autouse=True)
def no_test_env(monkeypatch):
    for name in ("API", "PREFIX", "HOSTS", "CA"):
        monkeypatch.delenv(f"GLASSBED_UPDATE_TEST_{name}", raising=False)


@pytest.fixture
def app():
    return QApplication.instance() or QApplication([])


@pytest.fixture
def settings(tmp_path):
    return QSettings(str(tmp_path / "glassbed.ini"), QSettings.Format.IniFormat)


@pytest.fixture
def english():
    old = i18n.LANG
    i18n.set_language("en")
    yield
    i18n.LANG = old


def wait(ms, until=lambda: False):
    end = time.monotonic() + ms / 1000
    while time.monotonic() < end and not until():
        QCoreApplication.processEvents()
        time.sleep(0.01)
    QCoreApplication.processEvents()


# -- versions -----------------------------------------------------------------
def test_parse_version():
    assert updates.parse_version("0.3.0") == (0, 3, 0)
    assert updates.parse_version("v1.2.3") == (1, 2, 3)
    for bad in ("1.2", "1.2.3-rc1", "", None):
        assert updates.parse_version(bad) is None


def test_is_newer_is_numeric():
    assert updates.is_newer("0.3.1", "0.3.0")
    assert updates.is_newer("0.10.0", "0.9.9")          # not a string comparison
    assert not updates.is_newer("0.3.0", "0.3.0")
    assert not updates.is_newer("0.2.9", "0.3.0")
    assert not updates.is_newer("garbage", "0.3.0")


# -- once a day -----------------------------------------------------------------
def test_check_due():
    now = datetime(2026, 11, 8, 12, 0, tzinfo=timezone.utc)
    assert updates.check_due(None, now) is True
    assert updates.check_due(updates.stamp(now - timedelta(hours=1)), now) is False
    assert updates.check_due(updates.stamp(now - timedelta(hours=25)), now) is True
    assert updates.check_due("not a date", now) is True
    assert updates.check_due(updates.stamp(now + timedelta(hours=3)), now) is True   # clock set back


def test_stamp_roundtrip():
    now = datetime(2026, 11, 8, 12, 30, 15, tzinfo=timezone.utc)
    assert datetime.fromisoformat(updates.stamp(now)) == now
    assert updates.check_due(updates.stamp()) is False


# -- skip -------------------------------------------------------------------------
def test_should_notify_respects_skip():
    rel = updates.Release("0.3.1", updates.RELEASES_URL)
    assert updates.should_notify(rel, "0.3.0", skipped="0.3.1") is False
    assert updates.should_notify(rel, "0.3.0", skipped="0.3.0") is True
    assert updates.should_notify(updates.Release("0.2.0", updates.RELEASES_URL), "0.3.0") is False
    assert updates.should_notify(None, "0.3.0") is False


# -- GitHub answer --------------------------------------------------------------
def api_answer(prefix=PREFIX + "v0.3.1/", **extra):
    data = {"tag_name": "v0.3.1", "draft": False, "prerelease": False,
            "html_url": "https://github.com/ARFEP-IT-Service/Glassbed/releases/tag/v0.3.1",
            "assets": [{"name": SETUP, "browser_download_url": prefix + SETUP},
                       {"name": SETUP + ".sha256", "browser_download_url": prefix + SETUP + ".sha256"}]}
    data.update(extra)
    return data


def test_parse_release_with_installer():
    rel = updates.parse_release(api_answer(), updates.Config())
    assert rel.version == "0.3.1"
    assert rel.page_url.endswith("/releases/tag/v0.3.1")
    assert rel.setup_name == SETUP
    assert rel.setup_url == PREFIX + "v0.3.1/" + SETUP
    assert rel.sha256_url == PREFIX + "v0.3.1/" + SETUP + ".sha256"


def test_parse_release_ignores_drafts_and_prereleases():
    cfg = updates.Config()
    assert updates.parse_release(api_answer(draft=True), cfg) is None
    assert updates.parse_release(api_answer(prerelease=True), cfg) is None
    assert updates.parse_release(api_answer(tag_name="v0.3.1-rc1"), cfg) is None
    assert updates.parse_release("not a dict", cfg) is None


def test_parse_release_foreign_assets_only_page():
    """Assets of another repository or host: offered as release page only."""
    cfg = updates.Config()
    for prefix in ("https://github.com/someone/Glassbed/releases/download/v0.3.1/",
                   "https://evil.example.com/ARFEP-IT-Service/Glassbed/releases/download/v0.3.1/"):
        rel = updates.parse_release(api_answer(prefix), cfg)
        assert rel is not None and rel.version == "0.3.1"
        assert rel.setup_url is None and rel.sha256_url is None and rel.setup_name is None


def test_parse_release_foreign_page_falls_back():
    rel = updates.parse_release(api_answer(html_url="https://evil.example.com/releases/1"), updates.Config())
    assert rel.page_url == updates.RELEASES_URL


# -- checksum file -----------------------------------------------------------------
def test_parse_sha256():
    h = "AB" * 32
    assert updates.parse_sha256(f"{h}  {SETUP}\n", SETUP) == h.lower()
    assert updates.parse_sha256(f"{h} *{SETUP}", SETUP) == h.lower()
    assert updates.parse_sha256(h, SETUP) == h.lower()
    with pytest.raises(updates.UpdateError):
        updates.parse_sha256(f"{h}  Other-setup.exe", SETUP)


# -- download (fake opener) ----------------------------------------------------------
class FakeResponse(io.BytesIO):
    def __init__(self, data):
        super().__init__(data)
        self.headers = {"Content-Length": str(len(data))}


@pytest.fixture
def opener(monkeypatch):
    """``updates._open`` answering from a dict of URL → bytes; records every URL."""
    files, calls = {}, []

    def fake_open(url, cfg, accept="*/*"):
        calls.append(url)
        updates.check_url(url, cfg)
        return FakeResponse(files[url])

    monkeypatch.setattr(updates, "_open", fake_open)
    return files, calls


def release_with(files, content, sha=None):
    rel = updates.Release("0.3.1", updates.RELEASES_URL, SETUP,
                          PREFIX + "v0.3.1/" + SETUP, PREFIX + "v0.3.1/" + SETUP + ".sha256")
    files[rel.setup_url] = content
    files[rel.sha256_url] = f"{sha or hashlib.sha256(content).hexdigest()}  {SETUP}\n".encode()
    return rel


def test_download_verified(opener, tmp_path):
    files, _ = opener
    content = b"MZ" + os.urandom(600 * 1024)
    seen = []
    target = updates.download(release_with(files, content), tmp_path, lambda d, t: seen.append((d, t)),
                              cfg=updates.Config())
    assert target == tmp_path / SETUP
    assert target.read_bytes() == content
    assert seen[-1] == (len(content), len(content))


def test_download_checksum_mismatch_deletes_file(opener, tmp_path):
    files, _ = opener
    rel = release_with(files, b"MZ tampered", sha="0" * 64)
    with pytest.raises(updates.UpdateError) as e:
        updates.download(rel, tmp_path, cfg=updates.Config())
    assert not isinstance(e.value, updates.Cancelled)
    assert list(tmp_path.iterdir()) == []


def test_download_cancel_deletes_file(opener, tmp_path):
    files, _ = opener
    rel = release_with(files, b"MZ" * 1000)
    with pytest.raises(updates.Cancelled):
        updates.download(rel, tmp_path, cancelled=lambda: True, cfg=updates.Config())
    assert list(tmp_path.iterdir()) == []


def test_download_refuses_foreign_url_before_connecting(opener, tmp_path):
    files, calls = opener
    for setup, sha in (("https://evil.example.com/" + SETUP, PREFIX + "v0.3.1/" + SETUP + ".sha256"),
                       (PREFIX + "v0.3.1/" + SETUP, "https://github.com/other/repo/" + SETUP + ".sha256")):
        rel = updates.Release("0.3.1", updates.RELEASES_URL, SETUP, setup, sha)
        with pytest.raises(updates.UpdateError):
            updates.download(rel, tmp_path, cfg=updates.Config())
    with pytest.raises(updates.UpdateError):
        updates.download(updates.Release("0.3.1", updates.RELEASES_URL), tmp_path, cfg=updates.Config())
    assert calls == []
    assert list(tmp_path.iterdir()) == []


# -- allowed hosts -----------------------------------------------------------------
def test_check_url():
    cfg = updates.Config()
    updates.check_url(updates.API_URL, cfg)
    updates.check_url(PREFIX + "v0.3.1/" + SETUP, cfg)
    for url in ("http://github.com/ARFEP-IT-Service/Glassbed", "https://evil.example.com/x",
                "https://github.com.evil.example.com/x", "https://github.com@evil.example.com/x",
                "ftp://github.com/x"):
        with pytest.raises(updates.UpdateError):
            updates.check_url(url, cfg)


def test_redirect_to_foreign_host_aborts():
    handler = updates._CheckedRedirects(updates.Config())
    req = urllib.request.Request(PREFIX + "v0.3.1/" + SETUP)
    with pytest.raises(updates.UpdateError):
        handler.redirect_request(req, None, 302, "Found", {}, "https://evil.example.com/x")
    with pytest.raises(updates.UpdateError):
        handler.redirect_request(req, None, 302, "Found", {}, "http://release-assets.githubusercontent.com/x")
    new = handler.redirect_request(req, None, 302, "Found", {},
                                   "https://release-assets.githubusercontent.com/github-production/x")
    assert new is not None and new.full_url.startswith("https://release-assets.githubusercontent.com/")


def test_open_refuses_foreign_host(monkeypatch, no_network):
    monkeypatch.setattr(urllib.request, "build_opener", lambda *a: pytest.fail("opener built"))
    for url in ("https://evil.example.com/x", "http://api.github.com/x"):
        with pytest.raises(updates.UpdateError):
            updates._open(url, updates.Config())
    assert no_network == []


# -- kind of installation (fake registry) ----------------------------------------------
class FakeRegistry:
    HKEY_CURRENT_USER = "HKCU"

    class _Key:
        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

    def __init__(self, location=None, fail=False):
        self.location, self.fail = location, fail

    def OpenKey(self, root, path):
        assert (root, path) == (self.HKEY_CURRENT_USER, updates.UNINSTALL_KEY)
        if self.fail:
            raise FileNotFoundError(path)
        return self._Key()

    def QueryValueEx(self, key, name):
        assert name == "InstallLocation"
        return self.location, 1


def test_install_kind(monkeypatch, tmp_path):
    monkeypatch.setattr(sys, "platform", "linux")
    assert updates.install_kind() == "unsupported"
    monkeypatch.setattr(sys, "platform", "win32")
    monkeypatch.delattr(sys, "frozen", raising=False)
    assert updates.install_kind() == "source"

    exe = tmp_path / "Glassbed.exe"
    exe.write_bytes(b"MZ")
    no_registry = FakeRegistry(fail=True)
    assert updates.install_kind(str(exe), FakeRegistry(str(tmp_path))) == "portable"     # no uninstall.exe
    (tmp_path / "uninstall.exe").write_bytes(b"MZ")
    assert updates.install_kind(str(exe), FakeRegistry(str(tmp_path))) == "installer"
    assert updates.install_kind(str(exe), FakeRegistry(str(tmp_path) + os.sep)) == "installer"
    assert updates.install_kind(str(exe), FakeRegistry(str(tmp_path / "elsewhere"))) == "portable"
    assert updates.install_kind(str(exe), no_registry) == "portable"


# -- test hook ----------------------------------------------------------------------
def test_update_testing_config(monkeypatch):
    assert _update_testing.config(updates.Config) is None
    assert updates.config() == updates.Config()
    monkeypatch.setenv("GLASSBED_UPDATE_TEST_API", "https://localhost:8443/latest")
    monkeypatch.setenv("GLASSBED_UPDATE_TEST_PREFIX", "https://localhost:8443/download/")
    monkeypatch.setenv("GLASSBED_UPDATE_TEST_HOSTS", " LocalHost , 127.0.0.1,")
    monkeypatch.setenv("GLASSBED_UPDATE_TEST_CA", "C:/certs/ca.pem")
    cfg = _update_testing.config(updates.Config)
    assert cfg == updates.Config(api_url="https://localhost:8443/latest",
                                 download_prefix="https://localhost:8443/download/",
                                 allowed_hosts=frozenset({"localhost", "127.0.0.1"}), cafile="C:/certs/ca.pem")
    assert updates.config() == cfg


# -- the window: question and consent ---------------------------------------------------
class FakeScanTab:
    def has_unsaved(self):
        return False


class FakeWindow(QMainWindow):
    def __init__(self, settings):
        super().__init__()
        self.settings = settings
        self.tray = None
        self.scan_tab = FakeScanTab()
        self.alerts = []
        self.setCentralWidget(QWidget())
        self.resize(800, 600)

    def show_alert(self, kind, title, text):
        self.alerts.append((kind, title, text))


@pytest.fixture
def window(app, settings, monkeypatch, english):
    monkeypatch.setattr(updates, "cleanup_temp", lambda: None)     # leave the real temp folder alone
    w = FakeWindow(settings)
    yield w
    w.close()
    w.deleteLater()
    QCoreApplication.processEvents()


@pytest.fixture
def fetches(monkeypatch):
    calls = []

    def fake_fetch(cfg=None):
        calls.append(cfg)
        return None

    monkeypatch.setattr(updates, "fetch_latest", fake_fetch)
    return calls


def buttons(overlay):
    return {b.text(): b for b in overlay.findChildren(QPushButton)}


def test_question_defaults_to_no(window, settings, fetches):
    ctl = UpdateController(window)
    assert ctl.needs_question() is True
    overlay = ctl.ask_once()
    assert isinstance(overlay, ConfirmOverlay)
    settings.sync()
    assert settings.value(update_ui.KEY_ASKED, False, type=bool) is True
    assert settings.value(update_ui.KEY_ENABLED, True, type=bool) is False     # closing now = No
    assert ctl.needs_question() is False

    found = buttons(overlay)
    assert set(found) == {"Yes", "No"}
    primary = [b for b in found.values() if b.objectName() == "primary"]
    assert [b.text() for b in primary] == ["No"]
    assert found["No"].isDefault() and not found["Yes"].isDefault()

    overlay.cancel()                                                            # Esc
    wait(100)
    assert settings.value(update_ui.KEY_ENABLED, True, type=bool) is False
    assert ctl.ask_once() is None
    assert fetches == []


def test_question_is_not_asked_twice(window, settings):
    ctl = UpdateController(window)
    assert ctl.ask_once() is not None
    assert ctl.ask_once() is None                                               # still open
    assert UpdateController(window).ask_once() is None                          # next start


def test_question_yes_enables(window, settings, monkeypatch):
    checks = []
    monkeypatch.setattr(UpdateController, "check", lambda self, silent, on_result=None: checks.append(silent))
    ctl = UpdateController(window)
    overlay = ctl.ask_once()
    buttons(overlay)["Yes"].click()
    assert settings.value(update_ui.KEY_ENABLED, False, type=bool) is True
    assert checks == [True]


def test_question_no_disables(window, settings, fetches):
    ctl = UpdateController(window)
    buttons(ctl.ask_once())["No"].click()
    wait(100)
    assert settings.value(update_ui.KEY_ENABLED, True, type=bool) is False
    assert fetches == []


@pytest.fixture
def no_delay(monkeypatch):
    monkeypatch.setattr(update_ui, "START_DELAY_MS", 0)


def test_no_check_without_consent(window, settings, fetches, no_delay):
    settings.setValue(update_ui.KEY_ENABLED, False)
    UpdateController(window).start()
    wait(200)
    assert fetches == []
    assert settings.value(update_ui.KEY_LAST) is None


def test_no_check_within_a_day(window, settings, fetches, no_delay):
    settings.setValue(update_ui.KEY_ENABLED, True)
    settings.setValue(update_ui.KEY_LAST, updates.stamp(datetime.now(timezone.utc) - timedelta(hours=1)))
    UpdateController(window).start()
    wait(200)
    assert fetches == []


def test_check_once_when_due(window, settings, fetches, no_delay):
    settings.setValue(update_ui.KEY_ENABLED, True)
    ctl = UpdateController(window)
    ctl.start()
    wait(3000, until=lambda: fetches and not ctl._checking)
    assert len(fetches) == 1
    assert ctl._checking is False and ctl.release is None
    assert updates.check_due(settings.value(update_ui.KEY_LAST)) is False
    assert window.alerts == []
