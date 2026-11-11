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


# texts added after 0.3.0 (devices that only print)
# and the device check
ADDED = {"This device cannot scan – printing only.", "Printer only", "Scanner + printer",
         "Only devices on the local network can be used ({host}).",
         "Check device", "Device check", "Checking the device…", "Copy report", "Share report", "Copied.", "Send this report to the developer if the device does not work with Glassbed. It contains the device's address, model and supported protocols – nothing else."}


def test_texts_unchanged_since_0_3_0():
    """Every text of 0.3.0 is still there and translated the same; only ADDED is new."""
    snap = json.loads((ROOT / "tests" / "fixtures" / "i18n-0.3.0.json").read_text(encoding="utf-8"))
    assert i18n.LANGUAGES == snap["languages"]
    for lang in LANGS:
        old, now = snap["translations"][lang], i18n.TRANSLATIONS[lang]
        assert set(now) - set(old) == ADDED
        assert {k: now[k] for k in old} == old


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
