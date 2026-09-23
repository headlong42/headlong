"""Small bits of bridge state: event dedupe and the active-thread set."""

from __future__ import annotations

import json
import threading
import time
from collections import OrderedDict, deque
from pathlib import Path

ACTIVE_THREAD_TTL = 7 * 24 * 3600


class Deduper:
    """Bounded set of recently seen event keys.

    A channel mention arrives as both app_mention and message.channels, and
    Socket Mode redelivers envelopes that are not acked in time.
    """

    def __init__(self, max_size: int = 5000):
        self._seen: OrderedDict[str, None] = OrderedDict()
        self._max_size = max_size
        self._lock = threading.Lock()

    def add(self, key: str) -> bool:
        """Record key; returns False if it was already seen."""
        with self._lock:
            if key in self._seen:
                return False
            self._seen[key] = None
            while len(self._seen) > self._max_size:
                self._seen.popitem(last=False)
            return True


class ActiveThreads:
    """Threads the bot participates in, so un-mentioned follow-ups reach it.

    Persisted as JSON ({"channel:thread_ts": last_touched_epoch}) so a bridge
    restart does not orphan ongoing conversations. Entries expire after
    ACTIVE_THREAD_TTL.
    """

    def __init__(self, path: Path):
        self._path = path
        self._lock = threading.Lock()
        self._threads: dict[str, float] = {}
        if path.is_file():
            try:
                data = json.loads(path.read_text())
                if isinstance(data, dict):
                    self._threads = {str(k): float(v) for k, v in data.items()}
            except (ValueError, TypeError):
                pass

    @staticmethod
    def _key(channel: str, thread_ts: str) -> str:
        return f"{channel}:{thread_ts}"

    def touch(self, channel: str, thread_ts: str | None) -> None:
        if not thread_ts:
            return
        with self._lock:
            self._prune()
            self._threads[self._key(channel, thread_ts)] = time.time()
            self._save()

    def is_active(self, channel: str, thread_ts: str | None) -> bool:
        if not thread_ts:
            return False
        with self._lock:
            self._prune()
            return self._key(channel, thread_ts) in self._threads

    def _prune(self) -> None:
        cutoff = time.time() - ACTIVE_THREAD_TTL
        stale = [k for k, v in self._threads.items() if v < cutoff]
        for k in stale:
            del self._threads[k]

    def _save(self) -> None:
        tmp = self._path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self._threads))
        tmp.replace(self._path)


class PeerGuard:
    """Bounds bot-to-bot traffic so two personas cannot talk forever.

    Two Headlong personas in one thread each answer every message the
    other posts. Without a bound that is an infinite loop billed to two
    LLM keys. Two limits, both counted on the messages this bridge
    forwards from peers:

    - per thread, at most `max_turns` peer messages in a row with no person
      speaking in the thread; a human message resets the count.
    - per hour, at most `hourly_cap` peer messages across all threads.

    In-memory only: a bridge restart resets the counts, and the hourly cap
    bounds what a restart loop could let through.
    """

    def __init__(self, max_turns: int, hourly_cap: int):
        self.max_turns = max_turns
        self.hourly_cap = hourly_cap
        self._runs: dict[str, int] = {}
        self._recent: deque[float] = deque()
        self._blocked: set[str] = set()
        self._lock = threading.Lock()

    @staticmethod
    def _key(channel: str, thread_ts: str | None) -> str:
        return f"{channel}:{thread_ts or ''}"

    def human_spoke(self, channel: str, thread_ts: str | None) -> None:
        """A person posted in this thread: peers may take turns again."""
        key = self._key(channel, thread_ts)
        with self._lock:
            self._runs.pop(key, None)
            self._blocked.discard(key)

    def allow(self, channel: str, thread_ts: str | None) -> tuple[bool, str]:
        """Record one forwarded peer message, or refuse it with a reason.

        The reason is empty when allowed, and empty on a repeat refusal
        for the same thread so the caller logs each block once.
        """
        key = self._key(channel, thread_ts)
        now = time.time()
        with self._lock:
            while self._recent and self._recent[0] < now - 3600:
                self._recent.popleft()
            reason = ""
            if len(self._recent) >= self.hourly_cap:
                reason = f"hourly cap of {self.hourly_cap} peer messages reached"
            elif self._runs.get(key, 0) >= self.max_turns:
                reason = (
                    f"{self.max_turns} peer messages in a row without a person; "
                    "waiting for someone to speak in the thread"
                )
            if reason:
                first = key not in self._blocked
                self._blocked.add(key)
                return False, (reason if first else "")
            self._runs[key] = self._runs.get(key, 0) + 1
            self._recent.append(now)
            return True, ""
