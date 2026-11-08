"""ARFEP IT-Service – the company behind Glassbed."""
from __future__ import annotations

from pathlib import Path

COMPANY = "ARFEP IT-Service"
CITY = "Göttingen"
ASSETS = Path(__file__).resolve().parent / "assets" / "arfep"

# legal pages (fixed links, the same for every language)
IMPRINT_URL = "https://arfep.de/impressum"
PRIVACY_URL = "https://arfep.de/datenschutz-glassbed"
PRIVACY_UPDATES_URL = PRIVACY_URL + "#update-pruefung"     # the section on the update check

# arfep.de has German at the root, English under /en/ and Turkish under /tr/
_PREFIX = {"de": "", "en": "en/", "tr": "tr/"}


def website(lang: str) -> str:
    return f"https://arfep.de/{_PREFIX.get(lang, 'en/')}"


def contact(lang: str) -> str:
    return website(lang) + "#kontakt"


def logo(dark: bool) -> Path:
    """Wordmark: white version on dark backgrounds, ink version on light ones."""
    return ASSETS / ("logo-white.svg" if dark else "logo-ink.svg")
