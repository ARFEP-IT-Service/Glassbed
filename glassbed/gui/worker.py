"""Run blocking work (network, rendering) off the GUI thread."""
from __future__ import annotations

from typing import Any, Callable

from PySide6.QtCore import QObject, QRunnable, Qt, QThreadPool, Signal

_active: set["Task"] = set()


class _Signals(QObject):
    done = Signal(object)
    failed = Signal(object)
    progress = Signal(object)


class Task(QRunnable):
    """Calls ``fn(progress, *args)`` in the thread pool.

    ``progress(value)`` may be called from the worker; every callback runs on the GUI thread.
    """

    def __init__(self, fn: Callable[..., Any], *args):
        super().__init__()
        self.setAutoDelete(False)
        self.fn, self.args = fn, args
        self.signals = _Signals()

    def run(self) -> None:
        try:
            result = self.fn(self.signals.progress.emit, *self.args)
        except BaseException as exc:  # noqa: BLE001 - reported to the GUI
            self.signals.failed.emit(exc)
        else:
            self.signals.done.emit(result)


def run_task(fn: Callable[..., Any], *args,
             on_done: Callable[[Any], None] | None = None,
             on_error: Callable[[BaseException], None] | None = None,
             on_progress: Callable[[Any], None] | None = None) -> Task:
    task = Task(fn, *args)
    _active.add(task)
    q = Qt.ConnectionType.QueuedConnection

    def finish(cb, value):
        _active.discard(task)
        if cb:
            cb(value)

    task.signals.done.connect(lambda r: finish(on_done, r), q)
    task.signals.failed.connect(lambda e: finish(on_error, e), q)
    if on_progress:
        task.signals.progress.connect(on_progress, q)
    QThreadPool.globalInstance().start(task)
    return task
