"""Which extra photo-model machines to try, and in what order (A3).

They take turns. One that can't be reached is skipped for a while, or a machine
that's switched off would cost every other photo its connection timeout. They're
off on ordinary days, so that's normal, not an error.
"""

import logging
import time

# Long enough not to keep paying for a dead machine, short enough to notice soon
# that one has come back.
SKIP_SECONDS = 30.0

_log = logging.getLogger(__name__)


class ModelMachines:
    def __init__(self, urls: list[str]) -> None:
        self._urls = urls
        self._next = 0
        self._skip_until: dict[str, float] = {}

    def order(self) -> list[str]:
        """The machines to try for this photo, the next one's turn first."""
        if not self._urls:
            return []
        start = self._next % len(self._urls)
        self._next += 1
        now = time.monotonic()
        return [
            url
            for url in self._urls[start:] + self._urls[:start]
            if self._skip_until.get(url, 0) <= now
        ]

    def skip(self, url: str, reason: str) -> None:
        _log.warning("skipping model machine %s for now: %s", url, reason)
        self._skip_until[url] = time.monotonic() + SKIP_SECONDS


def parse_urls(value: str | None) -> list[str]:
    """AI_TRAINING_URLS: comma-separated, like http://10.0.0.1,http://10.0.0.2."""
    return [url.strip().rstrip("/") for url in (value or "").split(",") if url.strip()]
