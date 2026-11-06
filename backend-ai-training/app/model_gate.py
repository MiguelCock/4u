"""How many photos the model handles at once, and who goes first.

Without a limit, every request ran the model in its own thread: overloaded, they
fought over the CPUs, answered too late to be useful, and their memory froze the
server (docs/loadtest/baseline.md). Here a user's photo waits briefly and is then
refused, so positioning can answer from GPS straight away. Indexing takes one
slot at most, and only when no user's photo is waiting.
"""

import threading
from collections.abc import Iterator
from contextlib import contextmanager


class ModelBusy(Exception):
    """No slot came free in time."""


class ModelGate:
    def __init__(self, slots: int, max_waiting: int = 8) -> None:
        self._slots = slots
        self._max_waiting = max_waiting
        self._running = 0
        self._indexing = 0
        self._searches_waiting = 0
        self._changed = threading.Condition()

    def _can_index(self) -> bool:
        return (
            self._running < self._slots
            and self._indexing == 0
            and self._searches_waiting == 0
        )

    @contextmanager
    def search(self, wait_seconds: float) -> Iterator[None]:
        with self._changed:
            # Past this many, a photo can't get its turn in time. Waiting would
            # only hold its memory and a thread (1.7 GB at 45 users).
            if (
                self._running >= self._slots
                and self._searches_waiting >= self._max_waiting
            ):
                raise ModelBusy
            self._searches_waiting += 1
            free = self._changed.wait_for(
                lambda: self._running < self._slots, wait_seconds
            )
            self._searches_waiting -= 1
            if not free:
                # Indexing may have been waiting on this search alone.
                self._changed.notify_all()
                raise ModelBusy
            self._running += 1
        try:
            yield
        finally:
            with self._changed:
                self._running -= 1
                self._changed.notify_all()

    @contextmanager
    def index(self, wait_seconds: float) -> Iterator[None]:
        with self._changed:
            if not self._changed.wait_for(self._can_index, wait_seconds):
                raise ModelBusy
            self._running += 1
            self._indexing += 1
        try:
            yield
        finally:
            with self._changed:
                self._running -= 1
                self._indexing -= 1
                self._changed.notify_all()
