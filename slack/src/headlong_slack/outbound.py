"""Mind log -> Slack.

Follows the identity's root trajectory and forwards message steps the
identity addressed to a slack-* conversation name. The bridge's own
inbound steps have a slack-* `from` (not the identity), so they never
match — no echo loop.
"""

from __future__ import annotations

import logging
import io
import threading
import time
from typing import Any

from . import mindlog, naming
from .config import Config
from .slackfmt import chunk, strip_leaked_command, to_mrkdwn
from .state import ActiveThreads
from .filepayload import file_payload

log = logging.getLogger(__name__)

DUPLICATE_WINDOW_SECONDS = 300


class RecentPosts:
    """Transport-level dedupe: agents occasionally send the same reply twice
    (e.g. an agentic run re-executing its chat command). Posting an identical
    message to the same conversation twice within the window is never right.
    """

    def __init__(self, window: float = DUPLICATE_WINDOW_SECONDS):
        self._window = window
        self._last: dict[str, tuple[str, float]] = {}

    def is_duplicate(self, conversation: str, text: str, now: float | None = None) -> bool:
        now = time.time() if now is None else now
        previous = self._last.get(conversation)
        if previous and previous[0] == text and now - previous[1] < self._window:
            return True
        self._last[conversation] = (text, now)
        return False


def run(
    cfg: Config,
    client: Any,
    threads: ActiveThreads,
    stop_event: threading.Event,
) -> None:
    traj = mindlog.find_trajectory(cfg.identity_dir)
    cursor = cfg.state_dir / "cursor"
    recent = RecentPosts()
    log.info("following %s", traj)
    for step in mindlog.follow(traj, cursor, should_stop=stop_event.is_set):
        if step.get("type") != "message" or step.get("from") != cfg.identity:
            continue
        if step.get("source") != "chat":
            # Only bin/chat speaks for the identity — it stamps source:"chat"
            # on every outgoing message. Thinkers sometimes append raw message
            # steps directly to the trajectory (thinking out loud, not a
            # reply); delivering those gives the user a second, unstamped
            # voice. Bridges are the mouth; the trajectory is the mind.
            log.warning(
                "dropping non-chat message step %s (source=%r)",
                step.get("step_id"),
                step.get("source"),
            )
            continue

        to = step.get("to")
        if not naming.is_slack_name(to):
            continue
        conv = naming.decode(to)

        payload = file_payload(step)
        if payload is not None:
            # File steps travel in content_b64 and often have empty `content`.
            # Do not require text, and do not fall back to posting bytes as a message.
            name = payload["filename"]
            data = payload["content"]
            caption = payload.get("caption")
            sent_file = False
            if payload.get("decode_error") or data is None:
                log.error("undecodable file payload for %s (%s)", to, name)
            else:
                try:
                    # Slack files_upload_v2 accepts bytes or file-like object
                    client.files_upload_v2(
                        channel=conv.channel,
                        thread_ts=conv.thread_ts,
                        file=io.BytesIO(data),
                        filename=name,
                        initial_comment=caption,
                    )
                    sent_file = True
                except Exception:
                    log.exception("files_upload_v2 failed for %s", to)
            if not sent_file:
                # Cursor already advanced past this step; tell the user
                # the upload was lost rather than failing silently.
                notice = f"(failed to deliver file {name})"
                try:
                    client.chat_postMessage(
                        channel=conv.channel,
                        thread_ts=conv.thread_ts,
                        text=notice,
                        unfurl_links=False,
                    )
                except Exception:
                    log.exception("delivery-failed notice also failed for %s", to)
            continue

        text = to_mrkdwn(strip_leaked_command(str(step.get("content") or ""))).strip()
        if not text:
            continue
        if recent.is_duplicate(to, text):
            log.warning("skipping duplicate post to %s", to)
            continue
        threads.touch(conv.channel, conv.thread_ts)
        for part in chunk(text):
            try:
                client.chat_postMessage(
                    channel=conv.channel,
                    thread_ts=conv.thread_ts,
                    text=part,
                    unfurl_links=False,
                )
            except Exception:
                log.exception("chat_postMessage failed for %s", to)
                break


def start(
    cfg: Config,
    client: Any,
    threads: ActiveThreads,
    stop_event: threading.Event,
) -> threading.Thread:
    thread = threading.Thread(
        target=run,
        args=(cfg, client, threads, stop_event),
        name="slack-outbound",
        daemon=True,
    )
    thread.start()
    return thread
