"""Legal links (legal notice, privacy) and "Learn more" for the update check.

The links open in the browser only when clicked: creating the views opens nothing and connects
to nothing (sockets are guarded, QDesktopServices.openUrl is recorded).
"""
import os
import socket

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PySide6.QtCore import QCoreApplication, QSettings  # noqa: E402
from PySide6.QtWidgets import QApplication, QMainWindow, QPushButton, QWidget  # noqa: E402

from glassbed import brand, i18n  # noqa: E402
from glassbed.gui import widgets  # noqa: E402
from glassbed.gui.settings_page import SettingsPage  # noqa: E402
from glassbed.gui.update_ui import UpdateController  # noqa: E402

IMPRINT = "https://arfep.de/impressum"
PRIVACY = "https://arfep.de/datenschutz-glassbed"
PRIVACY_UPDATES = "https://arfep.de/datenschutz-glassbed#update-pruefung"


@pytest.fixture(autouse=True)
def no_network(monkeypatch):
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


@pytest.fixture
def opened(monkeypatch):
    """Every URL handed to the browser."""
    urls = []
    monkeypatch.setattr(widgets.QDesktopServices, "openUrl", lambda url: urls.append(url.toString()))
    return urls


@pytest.fixture
def app():
    return QApplication.instance() or QApplication([])


@pytest.fixture
def settings(tmp_path):
    return QSettings(str(tmp_path / "glassbed.ini"), QSettings.Format.IniFormat)


@pytest.fixture
def language():
    old = i18n.LANG
    yield i18n.set_language
    i18n.set_language(old)


def test_fixed_urls():
    assert brand.IMPRINT_URL == IMPRINT
    assert brand.PRIVACY_URL == PRIVACY
    assert brand.PRIVACY_UPDATES_URL == PRIVACY_UPDATES


@pytest.mark.parametrize("lang, imprint, privacy, more", [
    ("de", "Impressum", "Datenschutz", "Mehr dazu"),
    ("en", "Legal notice", "Privacy", "Learn more"),
    ("tr", "Künye", "Gizlilik", "Daha fazla bilgi"),
])
def test_settings_links(app, settings, language, opened, lang, imprint, privacy, more):
    language(lang)
    page = SettingsPage(settings)
    QCoreApplication.processEvents()
    links = {"imprint": page.imprint_link, "privacy": page.privacy_link, "more": page.updates_more}
    assert {k: v.url for k, v in links.items()} == {"imprint": IMPRINT, "privacy": PRIVACY,
                                                    "more": PRIVACY_UPDATES}
    assert imprint in page.imprint_link.text() and privacy in page.privacy_link.text()
    assert more in page.updates_more.text()
    assert opened == []                         # nothing opens before a click
    for link in links.values():
        link.linkActivated.emit(link.url)       # what a click does
    assert opened == [IMPRINT, PRIVACY, PRIVACY_UPDATES]
    page.deleteLater()


def test_no_terms_link(app, settings, language):
    """Only legal notice and privacy – no terms and conditions."""
    language("de")
    page = SettingsPage(settings)
    urls = {w.url for w in page.findChildren(widgets.LinkLabel)}
    assert urls == {IMPRINT, PRIVACY, PRIVACY_UPDATES}
    assert not any("agb" in u.lower() or "terms" in u.lower() for u in urls)
    page.deleteLater()


class FakeWindow(QMainWindow):
    def __init__(self, settings):
        super().__init__()
        self.settings = settings
        self.tray = None
        self.setCentralWidget(QWidget())


def test_question_has_learn_more_link(app, settings, language, opened, monkeypatch):
    language("en")
    monkeypatch.setattr(UpdateController, "check", lambda *a, **k: pytest.fail("no check without consent"))
    window = FakeWindow(settings)
    overlay = UpdateController(window).ask_once()
    assert overlay.link is not None and overlay.link.url == PRIVACY_UPDATES
    assert "Learn more" in overlay.link.text()
    default = [b for b in overlay.findChildren(QPushButton) if b.isDefault()]
    assert [b.text() for b in default] == ["No"]                # the link does not change the default
    assert opened == []
    overlay.link.linkActivated.emit(overlay.link.url)
    assert opened == [PRIVACY_UPDATES]
    assert settings.value("update/enabled", False, type=bool) is False   # opening the link is no consent
    overlay.cancel()
    window.deleteLater()
