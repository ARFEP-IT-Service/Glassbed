"""Update check: versions, the daily rule, release parsing, allowed hosts, the Update button and the question.

No test touches the network, the browser or the real registry profile: sockets are guarded, the
opener, the registry and QDesktopServices.openUrl are fakes and settings live in an ini file under
tmp_path.
"""
import io
import json
import os
import socket
import sys
import time
import urllib.request
from dataclasses import fields
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
PAGE = "https://github.com/ARFEP-IT-Service/Glassbed/releases/tag/v0.3.1"


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
    data = {"tag_name": "v0.3.1", "draft": False, "prerelease": False, "html_url": PAGE,
            "assets": [{"name": SETUP, "browser_download_url": prefix + SETUP},
                       {"name": "Glassbed-0.3.1-portable.zip",
                        "browser_download_url": prefix + "Glassbed-0.3.1-portable.zip"}]}
    data.update(extra)
    return data


def test_release_shape():
    assert [f.name for f in fields(updates.Release)] == ["version", "page_url", "setup_url"]
    assert updates.Release("0.3.1", updates.RELEASES_URL).setup_url is None


def test_parse_release_with_installer():
    rel = updates.parse_release(api_answer(), updates.Config())
    assert rel == updates.Release("0.3.1", PAGE, PREFIX + "v0.3.1/" + SETUP)


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
                   "https://evil.example.com/ARFEP-IT-Service/Glassbed/releases/download/v0.3.1/",
                   "http://github.com/ARFEP-IT-Service/Glassbed/releases/download/v0.3.1/"):
        rel = updates.parse_release(api_answer(prefix), cfg)
        assert rel is not None and rel.version == "0.3.1"
        assert rel.page_url == PAGE
        assert rel.setup_url is None


def test_parse_release_setup_must_belong_to_the_tag():
    """A setup under another tag's folder (e.g. .../download/v0.3.0/ for v0.3.1) is not offered."""
    cfg = updates.Config()
    for folder in ("v0.3.0/", "v0.3.10/", "", "0.3.1/"):
        rel = updates.parse_release(api_answer(PREFIX + folder), cfg)
        assert rel is not None and rel.version == "0.3.1"
        assert rel.setup_url is None, folder


def test_parse_release_rejects_path_tricks():
    """Only the exact link .../download/vX/Glassbed-X-setup.exe is offered – no '..', no query."""
    cfg = updates.Config()
    for url in (PREFIX + "v0.3.1/../../../../someone/other/releases/download/v0.3.1/" + SETUP,
                PREFIX + "v0.3.1/x/" + SETUP, PREFIX + "v0.3.1/" + SETUP + "?x=1"):
        data = api_answer()
        data["assets"][0]["browser_download_url"] = url
        assert updates.parse_release(data, cfg).setup_url is None, url


def test_parse_release_without_matching_setup_asset():
    cfg = updates.Config()
    assert updates.parse_release(api_answer(assets=[]), cfg).setup_url is None
    other = [{"name": "Glassbed-0.3.0-setup.exe", "browser_download_url": PREFIX + "v0.3.1/x.exe"}]
    assert updates.parse_release(api_answer(assets=other), cfg).setup_url is None
    assert updates.parse_release(api_answer(assets=["junk", None]), cfg).setup_url is None


def test_parse_release_foreign_page_falls_back():
    rel = updates.parse_release(api_answer(html_url="https://evil.example.com/releases/1"), updates.Config())
    assert rel.page_url == updates.RELEASES_URL


def test_parse_release_uses_config_prefix():
    cfg = updates.Config(download_prefix="https://localhost:8443/download/")
    rel = updates.parse_release(api_answer("https://localhost:8443/download/v0.3.1/"), cfg)
    assert rel.setup_url == "https://localhost:8443/download/v0.3.1/" + SETUP
    assert updates.parse_release(api_answer(), cfg).setup_url is None


# -- nothing is downloaded or started --------------------------------------------------
@pytest.mark.parametrize("name", ["download", "start_installer", "cleanup_temp", "parse_sha256",
                                  "Cancelled", "temp_root", "new_temp_dir", "MAX_DOWNLOAD"])
def test_no_download_functionality(name):
    assert not hasattr(updates, name)


# -- allowed hosts -----------------------------------------------------------------
def test_allowed_hosts_is_only_the_api():
    assert updates.ALLOWED_HOSTS == frozenset({"api.github.com"})
    assert updates.Config().allowed_hosts == updates.ALLOWED_HOSTS


def test_check_url():
    cfg = updates.Config()
    updates.check_url(updates.API_URL, cfg)
    updates.check_url("https://API.GitHub.com/repos/x", cfg)
    for url in ("http://api.github.com/x", "https://evil.example.com/x",
                "https://api.github.com.evil.example.com/x", "https://api.github.com@evil.example.com/x",
                "ftp://api.github.com/x",
                PREFIX + "v0.3.1/" + SETUP, updates.RELEASES_URL,
                "https://release-assets.githubusercontent.com/github-production/x",
                "https://objects.githubusercontent.com/github-production/x"):
        with pytest.raises(updates.UpdateError):
            updates.check_url(url, cfg)


def test_redirect_only_to_the_api():
    handler = updates._CheckedRedirects(updates.Config())
    req = urllib.request.Request(updates.API_URL)
    for target in ("https://evil.example.com/x", "http://api.github.com/x",
                   "https://github.com/ARFEP-IT-Service/Glassbed/releases",
                   "https://release-assets.githubusercontent.com/github-production/x",
                   "https://objects.githubusercontent.com/github-production/x"):
        with pytest.raises(updates.UpdateError):
            handler.redirect_request(req, None, 302, "Found", {}, target)
    new = handler.redirect_request(req, None, 302, "Found", {},
                                   "https://api.github.com/repositories/1/releases/latest")
    assert new is not None and new.full_url.startswith("https://api.github.com/")


def test_open_refuses_foreign_host(monkeypatch, no_network):
    monkeypatch.setattr(urllib.request, "build_opener", lambda *a: pytest.fail("opener built"))
    for url in ("https://evil.example.com/x", "http://api.github.com/x", PREFIX + "v0.3.1/" + SETUP):
        with pytest.raises(updates.UpdateError):
            updates._open(url, updates.Config())
    assert no_network == []


def test_fetch_latest_asks_the_api_only(monkeypatch):
    calls = []

    def fake_open(url, cfg, accept="*/*"):
        calls.append((url, accept))
        updates.check_url(url, cfg)
        return io.BytesIO(json.dumps([api_answer()]).encode())

    monkeypatch.setattr(updates, "_open", fake_open)
    rel = updates.fetch_latest(updates.Config())
    assert calls == [(updates.API_URL, "application/vnd.github+json")]
    assert updates.API_URL.startswith("https://api.github.com/repos/ARFEP-IT-Service/Glassbed/releases?")
    assert rel == updates.Release("0.3.1", PAGE, PREFIX + "v0.3.1/" + SETUP)


# -- Windows and Android share the repository: only vX.Y.Z tags count ----------------------
def android_release(tag="android-v0.1.0", **extra):
    data = {"tag_name": tag, "draft": False, "prerelease": False,
            "html_url": "https://github.com/ARFEP-IT-Service/Glassbed/releases/tag/" + tag,
            "assets": [{"name": "glassbed-android.apk",
                        "browser_download_url": PREFIX + tag + "/glassbed-android.apk"}]}
    data.update(extra)
    return data


def windows_release(version, **extra):
    data = api_answer(PREFIX + f"v{version}/", tag_name=f"v{version}",
                      html_url=f"https://github.com/ARFEP-IT-Service/Glassbed/releases/tag/v{version}",
                      **extra)
    data["assets"][0] = {"name": f"Glassbed-{version}-setup.exe",
                         "browser_download_url": PREFIX + f"v{version}/Glassbed-{version}-setup.exe"}
    return data


def test_android_release_on_top_is_ignored():
    """The newest release is Android's – the Windows updater still offers the newest vX.Y.Z."""
    rel = updates.select_release([android_release(), windows_release("0.3.1"), windows_release("0.3.0")],
                                 updates.Config())
    assert rel is not None and rel.version == "0.3.1"
    assert rel.setup_url == PREFIX + "v0.3.1/Glassbed-0.3.1-setup.exe"


def test_only_android_releases_means_no_update():
    assert updates.select_release([android_release(), android_release("android-v0.2.0")],
                                  updates.Config()) is None


def test_drafts_and_prereleases_are_ignored():
    rel = updates.select_release([windows_release("0.4.0", draft=True),
                                  windows_release("0.3.9", prerelease=True),
                                  windows_release("0.3.1")], updates.Config())
    assert rel.version == "0.3.1"


def test_highest_v_version_wins_regardless_of_order():
    rel = updates.select_release([windows_release("0.3.1"), windows_release("0.10.0"),
                                  windows_release("0.9.2")], updates.Config())
    assert rel.version == "0.10.0"


def test_only_exact_v_tags_count():
    """No "0.4.0" without v, no "v0.4" or "v0.4.0-rc1", no other prefixes."""
    odd = [windows_release("0.3.1")]
    for tag in ("0.4.0", "v0.4", "v0.4.0-rc1", "release-v0.4.0", "V0.4.0", "v0.4.0 "):
        item = windows_release("0.4.0"); item["tag_name"] = tag; odd.append(item)
    assert updates.select_release(odd, updates.Config()).version == "0.3.1"


def test_fetch_latest_with_android_first(monkeypatch):
    answer = [android_release(), windows_release("0.3.1")]
    monkeypatch.setattr(updates, "_open", lambda url, cfg, accept="*/*": io.BytesIO(json.dumps(answer).encode()))
    assert updates.fetch_latest(updates.Config()).version == "0.3.1"


def test_fetch_latest_refuses_a_single_object(monkeypatch):
    """The list endpoint answers with a list; anything else is an unexpected answer."""
    monkeypatch.setattr(updates, "_open",
                        lambda url, cfg, accept="*/*": io.BytesIO(json.dumps(api_answer()).encode()))
    with pytest.raises(updates.UpdateError):
        updates.fetch_latest(updates.Config())


def test_fetch_latest_bad_answer(monkeypatch):
    monkeypatch.setattr(updates, "_open", lambda url, cfg, accept="*/*": io.BytesIO(b"<html>"))
    with pytest.raises(updates.UpdateError):
        updates.fetch_latest(updates.Config())


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
def window(app, settings, english):
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


# -- the Update button opens the browser; nothing is downloaded or started -----------------
REL_SETUP = updates.Release("0.3.1", PAGE, PREFIX + "v0.3.1/" + SETUP)
REL_PAGE = updates.Release("0.3.1", PAGE)


@pytest.fixture
def opened(monkeypatch):
    """QDesktopServices.openUrl as seen by update_ui; records the URL strings."""
    urls = []

    def fake_open_url(url):
        urls.append(url.toString())
        return True

    monkeypatch.setattr(update_ui.QDesktopServices, "openUrl", staticmethod(fake_open_url))
    return urls


def controller(window, kind, release):
    ctl = UpdateController(window)
    ctl.kind = kind
    ctl.release = release
    return ctl


def test_update_installer_opens_setup_link(window, opened):
    ctl = controller(window, "installer", REL_SETUP)
    assert ctl.update_url() == REL_SETUP.setup_url
    ctl.update_now()
    assert opened == [REL_SETUP.setup_url]
    assert len(window.alerts) == 1
    kind, title, _text = window.alerts[0]
    assert kind == "info" and "0.3.1" in title


@pytest.mark.parametrize("kind", ["portable", "source", "unsupported"])
def test_update_other_kinds_open_release_page(window, opened, kind):
    ctl = controller(window, kind, REL_SETUP)
    assert ctl.update_url() == PAGE
    ctl.update_now()
    assert opened == [PAGE]
    assert window.alerts == []


def test_update_installer_without_setup_opens_page(window, opened):
    ctl = controller(window, "installer", REL_PAGE)
    assert ctl.update_url() == PAGE
    ctl.update_now()
    assert opened == [PAGE]
    assert window.alerts == []


def test_update_without_release_opens_releases(window, opened):
    ctl = controller(window, "installer", None)
    assert ctl.update_url() == updates.RELEASES_URL
    ctl.update_now()
    assert opened == [updates.RELEASES_URL]
    assert window.alerts == []


def test_whats_new_opens_page(window, opened):
    controller(window, "installer", REL_SETUP).open_release_page()
    assert opened == [PAGE]
    assert window.alerts == []


@pytest.mark.parametrize("kind, release, expected, alerts", [
    ("installer", REL_SETUP, REL_SETUP.setup_url, 1),
    ("portable", REL_SETUP, PAGE, 0),
    ("installer", REL_PAGE, PAGE, 0),
])
def test_banner_update_button(window, opened, kind, release, expected, alerts):
    ctl = controller(window, kind, None)
    banner = update_ui.UpdateBanner(window.centralWidget())
    ctl.attach(banner)
    ctl.release = release
    banner.update_btn.click()
    assert opened == [expected]
    assert len(window.alerts) == alerts


def test_banner_has_no_progress_or_cancel(window):
    banner = update_ui.UpdateBanner(window.centralWidget())
    texts = sorted(b.text() for b in banner.findChildren(QPushButton))
    assert texts == sorted(["Update", "What's new", "Later", "Skip this version"])
