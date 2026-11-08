"""When to warn about low toner: below the threshold, at most once a day per colour."""
from __future__ import annotations

import re
from datetime import date
from typing import Iterable

THRESHOLD = 15          # percent; a warning is due strictly below this level
INTERVAL_MS = 30 * 60 * 1000


def alert_key(name: str) -> str:
    """Settings-safe key for a marker name ("Cyan Toner" -> "Cyan_Toner")."""
    return re.sub(r"[^A-Za-z0-9]+", "_", name).strip("_") or "toner"


def display_name(name: str) -> str:
    """Short colour name for a notification ("Cyan Toner" -> "Cyan")."""
    short = re.sub(r"\s*toner\s*$", "", name, flags=re.I).strip()
    return short or name


def is_low(level: int, threshold: int = THRESHOLD) -> bool:
    """Unknown levels (negative) never count as low."""
    return 0 <= level < threshold


def alerts_due(markers: Iterable, last_alerts: dict[str, str], today: date,
               threshold: int = THRESHOLD) -> list:
    """Markers that are low and have not been reported today yet.

    ``markers`` are objects with ``name`` and ``level`` (ipp.Marker);
    ``last_alerts`` maps alert_key(name) to the ISO date of the last warning.
    """
    stamp = today.isoformat()
    return [m for m in markers
            if is_low(m.level, threshold) and last_alerts.get(alert_key(m.name)) != stamp]


def record(last_alerts: dict[str, str], markers: Iterable, today: date) -> dict[str, str]:
    """Remember that these markers were reported today."""
    updated = dict(last_alerts)
    for m in markers:
        updated[alert_key(m.name)] = today.isoformat()
    return updated
