"""Tiny translation helper.

The texts live in shared/i18n.json – one file for the Windows and the Android app. The app loads
its copy, assets/i18n.json (written by tools/export_shared.py, packed into the build). Source
strings are English; anything without a translation falls back to English.
"""
from __future__ import annotations

import json
import locale
import os
from pathlib import Path

_DATA = json.loads((Path(__file__).resolve().parent / "assets" / "i18n.json").read_text(encoding="utf-8"))

# code -> name in its own language (shown in the language switcher)
LANGUAGES: dict[str, str] = dict(_DATA["languages"])

# language -> {English text: translation}
TRANSLATIONS: dict[str, dict[str, str]] = {
    lang: {key: entry[lang] for key, entry in _DATA["texts"].items() if entry.get(lang)}
    for lang in LANGUAGES if lang != "en"
}


def _system_language() -> str:
    try:
        from PySide6.QtCore import QLocale
        code = QLocale.system().name()[:2].lower()
    except Exception:
        code = (locale.getlocale()[0] or "en")[:2].lower()
    return code if code in LANGUAGES else "en"


def _initial_language() -> str:
    env = os.environ.get("GLASSBED_LANG", "")[:2].lower()
    if env in LANGUAGES:
        return env
    try:
        from . import config
        saved = config.settings().value("ui/language", "")
        if saved in LANGUAGES:
            return saved
    except Exception:
        pass
    return _system_language()


LANG = _initial_language()


def set_language(code: str) -> None:
    global LANG
    if code in LANGUAGES:
        LANG = code


def tr(text: str, **kwargs) -> str:
    out = TRANSLATIONS.get(LANG, {}).get(text, text)
    return out.format(**kwargs) if kwargs else out
