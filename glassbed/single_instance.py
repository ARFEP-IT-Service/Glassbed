"""Only one Glassbed window: a second start hands its files to the running app and exits."""
from __future__ import annotations

import getpass
import json
import os
import re
from typing import Callable

from PySide6.QtNetwork import QLocalServer, QLocalSocket

from . import config


def _server_name() -> str:
    user = re.sub(r"[^A-Za-z0-9_-]", "_", getpass.getuser())
    return f"glassbed-{config.profile()}-{user}"


def hand_over(files: list[str]) -> bool:
    """If Glassbed already runs, send it our files and return True (caller should exit)."""
    sock = QLocalSocket()
    sock.connectToServer(_server_name())
    if not sock.waitForConnected(400):
        return False
    if os.name == "nt":
        # allow the running instance to bring its window to the foreground
        try:
            import ctypes
            ctypes.windll.user32.AllowSetForegroundWindow(-1)
        except Exception:  # noqa: BLE001
            pass
    sock.write(json.dumps([os.path.abspath(f) for f in files]).encode("utf-8"))
    sock.flush()
    sock.waitForBytesWritten(1000)
    sock.disconnectFromServer()
    return True


class InstanceServer:
    """Listens for later starts and calls ``on_activate(files)`` for each one."""

    def __init__(self, on_activate: Callable[[list[str]], None]):
        self._on_activate = on_activate
        self._server = QLocalServer()
        name = _server_name()
        QLocalServer.removeServer(name)            # clean up after a crash
        self._server.listen(name)
        self._server.newConnection.connect(self._accept)

    def _accept(self) -> None:
        while self._server.hasPendingConnections():
            sock = self._server.nextPendingConnection()
            buf = bytearray()

            def read(sock=sock, buf=buf):
                buf.extend(bytes(sock.readAll()))

            def done(sock=sock, buf=buf):
                buf.extend(bytes(sock.readAll()))
                try:
                    files = json.loads(buf.decode("utf-8") or "[]")
                except ValueError:
                    files = []
                self._on_activate([f for f in files if isinstance(f, str)])
                sock.deleteLater()

            sock.readyRead.connect(read)
            sock.disconnected.connect(done)
