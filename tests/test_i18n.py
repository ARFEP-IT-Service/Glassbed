"""Texts come from shared/i18n.json: complete for every text the app uses, unchanged since 0.3.0."""
import ast
import json
import re
from pathlib import Path

from glassbed import i18n

ROOT = Path(__file__).resolve().parent.parent
LANGS = ("de", "tr")


def used_texts() -> set[str]:
    """Every tr("…") literal in the Windows app's source."""
    found = set()
    for path in (ROOT / "glassbed").rglob("*.py"):
        for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"))):
            if (isinstance(node, ast.Call) and getattr(node.func, "id", getattr(node.func, "attr", None)) == "tr"
                    and node.args and isinstance(node.args[0], ast.Constant) and isinstance(node.args[0].value, str)):
                found.add(node.args[0].value)
    return found


def test_the_app_loads_an_exact_copy_of_shared():
    assert (ROOT / "glassbed" / "assets" / "i18n.json").read_bytes() == (ROOT / "shared" / "i18n.json").read_bytes()


def test_every_used_text_exists_in_all_languages():
    texts = json.loads((ROOT / "shared" / "i18n.json").read_text(encoding="utf-8"))["texts"]
    used = used_texts()
    assert len(used) > 100
    missing = sorted(t for t in used if t not in texts or any(not texts[t].get(lang) for lang in ("en", *LANGS)))
    assert missing == []
    for lang in LANGS:
        assert used <= set(i18n.TRANSLATIONS[lang])


def test_placeholders_match():
    texts = json.loads((ROOT / "shared" / "i18n.json").read_text(encoding="utf-8"))["texts"]
    for key, entry in texts.items():
        holes = {lang: sorted(re.findall(r"\{(\w+)\}", entry[lang])) for lang in ("en", *LANGS)}
        assert len({tuple(v) for v in holes.values()}) == 1, key


# the in-app update replaced the two "download in your browser" texts with its own
UPDATE_REMOVED = {"Glassbed {version} is downloading in your browser",
                  "Start the setup after the download – your settings are kept."}
UPDATE_ADDED = {"Downloading Glassbed {version}…", "Starting the setup…", "Update failed", "Save your scans first",
                "Glassbed closes for the update. Save or remove the scanned pages first."}


def test_texts_unchanged_since_0_3_0():
    """Every text of 0.3.0 is still translated the same; only the update texts changed."""
    snap = json.loads((ROOT / "tests" / "fixtures" / "i18n-0.3.0.json").read_text(encoding="utf-8"))
    assert i18n.LANGUAGES == snap["languages"]
    for lang in LANGS:
        old, now = snap["translations"][lang], i18n.TRANSLATIONS[lang]
        assert set(old) - set(now) == UPDATE_REMOVED
        assert set(now) - set(old) == UPDATE_ADDED
        assert {k: v for k, v in now.items() if k in old} == {k: v for k, v in old.items() if k in now}


def test_english_falls_back_to_the_source_text():
    old = i18n.LANG
    try:
        i18n.set_language("en")
        assert i18n.tr("Scan") == "Scan"
        i18n.set_language("de")
        assert i18n.tr("Scan") == "Scannen"
        assert i18n.tr("{n} page(s)", n=3) == "3 Seite(n)"
    finally:
        i18n.set_language(old)
