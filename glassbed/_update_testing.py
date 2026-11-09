"""Test hook for the update check: point it at a local test release.

Only for development and the end-to-end test. build.ps1 leaves this module out of the release
build (``--exclude-module glassbed._update_testing``), so these variables do nothing there.

    GLASSBED_UPDATE_TEST_API     URL of the release list answer
    GLASSBED_UPDATE_TEST_PREFIX  URL prefix the download links must start with
    GLASSBED_UPDATE_TEST_HOSTS   comma-separated host names that may be contacted
    GLASSBED_UPDATE_TEST_CA      CA certificate file of the local HTTPS server
    GLASSBED_UPDATE_TEST_KIND    pretend this install kind ("installer"), so a test build in dist                                 can run the in-app update without touching a real installation
"""
from __future__ import annotations

import os


def config(cls):
    api = os.environ.get("GLASSBED_UPDATE_TEST_API")
    if not api:
        return None
    hosts = frozenset(h.strip().lower() for h in os.environ.get("GLASSBED_UPDATE_TEST_HOSTS", "").split(",")
                      if h.strip())
    return cls(api_url=api, download_prefix=os.environ.get("GLASSBED_UPDATE_TEST_PREFIX", ""),
               allowed_hosts=hosts, download_hosts=hosts, cafile=os.environ.get("GLASSBED_UPDATE_TEST_CA") or None)


def install_kind() -> str | None:
    return os.environ.get("GLASSBED_UPDATE_TEST_KIND") or None
