"""Inbound reaction filter: only our messages (and DMs) land in the mind log."""

from headlong_slack.inbound import reaction_text, reaction_to_inbound
from types import SimpleNamespace

from headlong_slack import inbound

BOT = "U_BOT"


def _event(
    *,
    user="U_NICK",
    reaction="thumbsup",
    channel="C_CHAN",
    ts="111.222",
    item_user="U_BOT",
    item_type="message",
    bot_id=None,
):
    event = {
        "type": "reaction_added",
        "user": user,
        "reaction": reaction,
        "item_user": item_user,
        "item": {"type": item_type, "channel": channel, "ts": ts},
        "event_ts": "999.000",
    }
    if bot_id is not None:
        event["bot_id"] = bot_id
    return event


def test_channel_reaction_on_our_message():
    got = reaction_to_inbound(_event(), bot_user_id=BOT)
    assert got == ("U_NICK", "C_CHAN", "111.222", "thumbsup", True)


def test_channel_reaction_on_someone_else_dropped():
    assert (
        reaction_to_inbound(_event(item_user="U_OTHER"), bot_user_id=BOT) is None
    )


def test_dm_reaction_on_anyone():
    got = reaction_to_inbound(
        _event(channel="D_DM", item_user="U_OTHER"), bot_user_id=BOT
    )
    assert got == ("U_NICK", "D_DM", "111.222", "thumbsup", False)


def test_bot_reacting_dropped():
    assert reaction_to_inbound(_event(user=BOT), bot_user_id=BOT) is None


def test_non_message_item_dropped():
    assert reaction_to_inbound(_event(item_type="file"), bot_user_id=BOT) is None


def test_missing_reaction_dropped():
    event = _event()
    del event["reaction"]
    assert reaction_to_inbound(event, bot_user_id=BOT) is None


def test_bot_id_dropped():
    assert reaction_to_inbound(_event(bot_id="B123"), bot_user_id=BOT) is None


def test_plus_one_name_preserved():
    got = reaction_to_inbound(_event(reaction="+1"), bot_user_id=BOT)
    assert got[3] == "+1"


def test_reaction_text_same_item_is_just_emoji():
    assert reaction_text("thumbsup", "111.222", "111.222") == ":thumbsup:"
    assert reaction_text("+1", "111.222", None) == ":+1:"


def test_reaction_text_nested_item_keeps_line():
    assert (
        reaction_text("thumbsup", "111.333", "111.222")
        == ":thumbsup: (on 111.333)"
    )


# -- worker-path coverage (Nick #88 review) ---------------------------------

import logging
import time

import httpx
import pytest

from headlong_slack.config import Config
from headlong_slack.inbound import Inbound
from headlong_slack.state import ActiveThreads


BOT = "U_BOT"
NICK = "U_NICK"
CHAN = "C_CHAN"
DM = "D_DM"
PARENT = "111.222"
REPLY = "111.333"


class _FakeApp:
    def __init__(self, client):
        self.client = client
        self.handlers = {}

    def event(self, name):
        def deco(fn):
            self.handlers[name] = fn
            return fn
        return deco


class _FakeClient:
    def __init__(self, message=None, raise_exc=False, delay=0.0, permalink_delay=0.0):
        self.message = message
        self.raise_exc = raise_exc
        self.delay = delay
        self.permalink_delay = permalink_delay
        self.reactions_get_calls = []
        self.permalink_calls = []
        self.replies_calls = []
        self.replies_messages = []
        self.replies_delay = 0.0
        self.replies_exc = False
        self._live = 0
        self.max_live = 0
        self._lock = __import__("threading").Lock()

    def reactions_get(self, *, channel, timestamp):
        self.reactions_get_calls.append((channel, timestamp))
        with self._lock:
            self._live += 1
            if self._live > self.max_live:
                self.max_live = self._live
        try:
            if self.delay:
                time.sleep(self.delay)
            if self.raise_exc:
                raise RuntimeError("lookup failed")
            return {"ok": True, "message": dict(self.message or {})}
        finally:
            with self._lock:
                self._live -= 1

    def users_info(self, user):
        return {
            "user": {
                "profile": {"display_name": "Nick Jalbert"},
                "real_name": "Nick Jalbert",
                "name": "nick",
            }
        }

    def chat_getPermalink(self, *, channel, message_ts):
        self.permalink_calls.append((channel, message_ts))
        if self.permalink_delay:
            time.sleep(self.permalink_delay)
        return {"permalink": f"https://slack.test/{channel}/p{message_ts}"}

    def conversations_info(self, channel):
        if channel.startswith("D"):
            return {"channel": {"is_im": True, "user": NICK}}
        return {"channel": {"name": "headlong-bot", "is_im": False}}

    def chat_postMessage(self, **kwargs):
        raise AssertionError(f"unexpected chat_postMessage {kwargs}")

    def conversations_replies(self, *, channel, ts, latest=None, inclusive=None,
                              limit=None, cursor=None, **_kw):
        self.replies_calls.append(
            {"channel": channel, "ts": ts, "latest": latest,
             "inclusive": inclusive, "limit": limit, "cursor": cursor}
        )
        with self._lock:
            self._live += 1
            if self._live > self.max_live:
                self.max_live = self._live
        try:
            if self.replies_delay:
                time.sleep(self.replies_delay)
            if self.replies_exc:
                raise RuntimeError("replies failed")
            msgs = list(self.replies_messages)

            def _key(m):
                try:
                    return float(m.get("ts") or 0)
                except (TypeError, ValueError):
                    return 0.0

            if latest is not None:
                cut = float(latest)
                if inclusive:
                    msgs = [m for m in msgs if _key(m) <= cut]
                else:
                    msgs = [m for m in msgs if _key(m) < cut]
            start = int(cursor) if cursor else 0
            if limit is None:
                page = msgs[start:]
            else:
                page = msgs[start:start + int(limit)]
            next_cursor = ""
            if limit is not None and start + int(limit) < len(msgs):
                next_cursor = str(start + int(limit))
            out = {"ok": True, "messages": page}
            if next_cursor:
                out["response_metadata"] = {"next_cursor": next_cursor}
            return out
        finally:
            with self._lock:
                self._live -= 1


def _cfg(tmp_path, followups=True, join_backfill=20):
    serve = tmp_path / "serve"
    ident = serve / "audel"
    ident.mkdir(parents=True)
    state = tmp_path / "state"
    state.mkdir()
    return Config(
        serve_root=serve,
        identity="audel",
        identity_dir=ident,
        bot_token="xoxb-test",
        app_token="xapp-test",
        web_url="http://127.0.0.1:9",
        state_dir=state,
        thread_followups=followups,
        thread_join_backfill=join_backfill,
    )


def _reaction_event(*, channel=CHAN, item_ts=PARENT, event_ts="999.000",
                    user=NICK, item_user=BOT, reaction="thumbsup"):
    return {
        "type": "reaction_added",
        "user": user,
        "reaction": reaction,
        "item_user": item_user,
        "item": {"type": "message", "channel": channel, "ts": item_ts},
        "event_ts": event_ts,
        "channel_type": "im" if channel.startswith("D") else "channel",
    }


class _Posted:
    def __init__(self):
        self.items = []

    def __call__(self, url, json=None, timeout=None):
        self.items.append({"url": url, "json": json, "timeout": timeout})
        class _R:
            def raise_for_status(self_inner):
                return None
        return _R()


@pytest.fixture
def posted(monkeypatch):
    p = _Posted()
    monkeypatch.setattr("headlong_slack.inbound.httpx.post", p)
    return p


def _run_reaction(tmp_path, client, event, posted, followups=True):
    cfg = _cfg(tmp_path, followups=followups)
    threads = ActiveThreads(cfg.state_dir / "threads.json")
    ib = Inbound(cfg, _FakeApp(client), BOT, threads)
    logger = logging.getLogger("test")
    try:
        ib._on_reaction(event, logger)
        deadline = time.time() + 2
        while time.time() < deadline and not posted.items:
            time.sleep(0.02)
        # small extra settle for a second unexpected post
        time.sleep(0.05)
    finally:
        ib.stop()
        ib._worker.join(timeout=1)
    return threads


def test_reaction_on_threaded_reply_rewrites_from_name_and_body(tmp_path, posted):
    client = _FakeClient(message={"ts": REPLY, "thread_ts": PARENT, "text": "hi"})
    event = _reaction_event(item_ts=REPLY)
    threads = _run_reaction(tmp_path, client, event, posted)
    assert client.reactions_get_calls == [(CHAN, REPLY)]
    assert len(posted.items) == 1
    body = posted.items[0]["json"]
    assert body["from_name"] == f"slack-{NICK}-{CHAN}-{PARENT}"
    assert ":thumbsup: (on 111.333)" in body["content"]
    assert "reply with: chat reply slack-U_NICK-C_CHAN-111.222" in body["content"]
    # A reaction must not open the un-mentioned-reply gate.
    assert not threads.is_active(CHAN, PARENT)


def test_reaction_lookup_empty_falls_back_to_item_ts(tmp_path, posted):
    client = _FakeClient(message={})
    event = _reaction_event(item_ts=PARENT)
    _run_reaction(tmp_path, client, event, posted)
    assert client.reactions_get_calls == [(CHAN, PARENT)]
    assert len(posted.items) == 1
    body = posted.items[0]["json"]
    assert body["from_name"] == f"slack-{NICK}-{CHAN}-{PARENT}"
    assert ":thumbsup:" in body["content"]
    assert "(on " not in body["content"]


def test_reaction_lookup_raising_falls_back_without_exception(tmp_path, posted):
    client = _FakeClient(raise_exc=True)
    event = _reaction_event(item_ts=PARENT)
    _run_reaction(tmp_path, client, event, posted)
    assert client.reactions_get_calls == [(CHAN, PARENT)]
    assert len(posted.items) == 1
    body = posted.items[0]["json"]
    assert body["from_name"] == f"slack-{NICK}-{CHAN}-{PARENT}"
    assert ":thumbsup:" in body["content"]


def test_reaction_lookup_timeouts_share_one_worker(tmp_path, posted, monkeypatch):
    """Nick #88: do not queue stale lookups after a timeout.

    One in-flight reactions.get; later reactions fail open immediately
    instead of submitting more work. A human message after the burst
    is delivered after at most one short timeout.
    """
    monkeypatch.setattr(inbound, "ITEM_LOOKUP_TIMEOUT", 0.05)
    client = _FakeClient(delay=0.8)
    cfg = _cfg(tmp_path)
    threads = ActiveThreads(cfg.state_dir / "threads.json")
    ib = Inbound(cfg, _FakeApp(client), BOT, threads)
    logger = logging.getLogger("test")
    try:
        t0 = time.time()
        for i in range(8):
            ib._on_reaction(_reaction_event(event_ts=f"999.{i:03d}"), logger)
        ib._on_event(
            {
                "type": "message",
                "user": NICK,
                "text": "hello after burst",
                "channel": DM,
                "ts": "200.000",
                "channel_type": "im",
            },
            logger,
        )
        deadline = t0 + 3
        while time.time() < deadline and len(posted.items) < 9:
            time.sleep(0.02)
        elapsed = time.time() - t0
        assert len(posted.items) == 9, posted.items
        assert client.max_live == 1
        # Only the first lookup is submitted; the rest skip while it runs.
        assert len(client.reactions_get_calls) == 1
        # Eight 2s waits would be 16s; one 50ms timeout plus delivery is far less.
        assert elapsed < 1.0, elapsed
        assert "hello after burst" in posted.items[-1]["json"]["content"]
        for item in posted.items[:-1]:
            assert item["json"]["from_name"] == f"slack-{NICK}-{CHAN}-{PARENT}"
            assert ":thumbsup:" in item["json"]["content"]
    finally:
        ib.stop()
        ib._worker.join(timeout=1)


def test_reaction_permalink_does_not_stall_later_message(tmp_path, posted):
    """Nick #88: reaction permalink must not run on the drain thread."""
    client = _FakeClient(permalink_delay=0.8)
    cfg = _cfg(tmp_path)
    threads = ActiveThreads(cfg.state_dir / "threads.json")
    ib = Inbound(cfg, _FakeApp(client), BOT, threads)
    logger = logging.getLogger("test")
    try:
        ib._on_reaction(_reaction_event(channel=DM, item_ts=PARENT), logger)
        ib._on_event(
            {
                "type": "message",
                "user": NICK,
                "text": "human after reaction",
                "channel": DM,
                "ts": "200.001",
                "channel_type": "im",
            },
            logger,
        )
        t0 = time.time()
        deadline = t0 + 3
        while time.time() < deadline and len(posted.items) < 2:
            time.sleep(0.02)
        elapsed = time.time() - t0
        assert len(posted.items) == 2, posted.items
        # Reaction skipped permalink; only the human waits 0.8s.
        assert elapsed < 1.2, elapsed
        assert client.permalink_calls == [(DM, "200.001")]
        assert "source_url" not in posted.items[0]["json"]
        assert posted.items[1]["json"].get("source_url")
        assert "human after reaction" in posted.items[1]["json"]["content"]
        assert ":thumbsup:" in posted.items[0]["json"]["content"]
    finally:
        ib.stop()
        ib._worker.join(timeout=1)


def test_dm_reaction_skips_lookup(tmp_path, posted):
    client = _FakeClient(message={"ts": PARENT, "thread_ts": PARENT})
    event = _reaction_event(channel=DM, item_ts=PARENT)
    _run_reaction(tmp_path, client, event, posted)
    assert client.reactions_get_calls == []
    assert len(posted.items) == 1
    body = posted.items[0]["json"]
    assert body["from_name"] == f"slack-{NICK}-{DM}"
    assert ":thumbsup:" in body["content"]
    assert "(on " not in body["content"]


def test_duplicate_reaction_envelope_dropped_by_dedupe(tmp_path, posted):
    client = _FakeClient(message={"ts": PARENT})
    cfg = _cfg(tmp_path)
    threads = ActiveThreads(cfg.state_dir / "threads.json")
    ib = Inbound(cfg, _FakeApp(client), BOT, threads)
    logger = logging.getLogger("test")
    event = _reaction_event(event_ts="999.000")
    try:
        ib._on_reaction(event, logger)
        ib._on_reaction(event, logger)
        deadline = time.time() + 2
        while time.time() < deadline and not posted.items:
            time.sleep(0.02)
        time.sleep(0.1)
    finally:
        ib.stop()
        ib._worker.join(timeout=1)
    assert len(posted.items) == 1
    assert len(client.reactions_get_calls) == 1

class OkResponse:
    def raise_for_status(self):
        pass


class Names:
    def user(self, _user):
        return "Dana"

    def place(self, _channel):
        return "#agents"


def make_inbound(client):
    bridge = inbound.Inbound.__new__(inbound.Inbound)
    bridge.bot_user_id = "UBOT"
    bridge.names = Names()
    bridge.app = SimpleNamespace(client=client)
    bridge._chat_url = "http://headlong.test/chat"
    return bridge


def test_deliver_records_slack_permalink(monkeypatch):
    posts = []

    class Client:
        def chat_getPermalink(self, channel, message_ts):
            assert (channel, message_ts) == ("C123", "1788451200.123456")
            return {
                "permalink": "https://laudesters.slack.com/archives/C123/p1788451200123456"
            }

    monkeypatch.setattr(
        inbound.httpx,
        "post",
        lambda url, json, timeout: posts.append((url, json, timeout)) or OkResponse(),
    )

    bridge = make_inbound(Client())
    bridge._deliver(
        inbound.InboundMessage(
            "slack-U123-C123-1788451200.123456",
            "U123",
            "C123",
            "1788451200.123456",
            "1788451200.123456",
            "<@UBOT> can you check this?",
        )
    )

    assert posts[0][1]["source_url"] == (
        "https://laudesters.slack.com/archives/C123/p1788451200123456"
    )
    assert posts[0][1]["from_name"] == "slack-U123-C123-1788451200.123456"


def test_permalink_failure_does_not_drop_message(monkeypatch):
    posts = []

    class Client:
        def chat_getPermalink(self, **_kwargs):
            raise RuntimeError("Slack is unavailable")

    monkeypatch.setattr(
        inbound.httpx,
        "post",
        lambda url, json, timeout: posts.append(json) or OkResponse(),
    )

    bridge = make_inbound(Client())
    bridge._deliver(
        inbound.InboundMessage(
            "slack-U123-D123",
            "U123",
            "D123",
            None,
            "1788451200.123456",
            "hello",
        )
    )

    assert len(posts) == 1
    assert "source_url" not in posts[0]



def _message_event(*, text, ts="111.500", thread_ts=PARENT, channel=CHAN,
                   user=NICK, event_type="app_mention", channel_type="channel"):
    event = {
        "type": event_type,
        "user": user,
        "text": text,
        "channel": channel,
        "ts": ts,
        "channel_type": channel_type,
    }
    if thread_ts is not None:
        event["thread_ts"] = thread_ts
    return event


def _run_message(tmp_path, client, event, posted, followups=True, join_backfill=20,
                 threads=None):
    cfg = _cfg(tmp_path, followups=followups, join_backfill=join_backfill)
    if threads is None:
        threads = ActiveThreads(cfg.state_dir / "threads.json")
    ib = Inbound(cfg, _FakeApp(client), BOT, threads)
    logger = logging.getLogger("test")
    try:
        ib._on_event(event, logger)
        deadline = time.time() + 2
        while time.time() < deadline and not posted.items:
            time.sleep(0.02)
        time.sleep(0.05)
    finally:
        ib.stop()
        ib._worker.join(timeout=1)
    return threads


def test_first_mention_in_thread_prepends_capped_prior_lines(tmp_path, posted):
    client = _FakeClient()
    mention_ts = "111.500"
    client.replies_messages = [
        {"ts": PARENT, "user": NICK, "text": "context one"},
        {"ts": "111.300", "user": NICK, "text": "context two"},
        {"ts": "111.400", "user": NICK, "text": "context three"},
        {"ts": mention_ts, "user": NICK, "text": f"<@{BOT}> what do you think?"},
    ]
    event = _message_event(text=f"<@{BOT}> what do you think?", ts=mention_ts)
    _run_message(tmp_path, client, event, posted, join_backfill=2)

    assert len(posted.items) == 1
    body = posted.items[0]["json"]["content"]
    assert "thread before this mention — 2 earlier messages" in body
    assert "context one" not in body
    assert "Nick Jalbert: context two" in body
    assert "Nick Jalbert: context three" in body
    assert "what do you think?" in body
    assert client.replies_calls
    assert client.replies_calls[0]["ts"] == PARENT
    assert client.replies_calls[0]["latest"] == mention_ts
    assert client.replies_calls[0]["inclusive"] is False


def test_join_backfill_cap_is_closest_prior_on_long_thread(tmp_path, posted):
    """Nick #108: fake must honor limit; cap is the latest context, not the oldest page."""
    client = _FakeClient()
    mention_ts = "111.500"
    client.replies_messages = [
        {"ts": PARENT, "user": NICK, "text": "parent"},
        {"ts": "111.301", "user": NICK, "text": "early one"},
        {"ts": "111.302", "user": NICK, "text": "early two"},
        {"ts": "111.303", "user": NICK, "text": "late one"},
        {"ts": "111.304", "user": NICK, "text": "late two"},
        {"ts": mention_ts, "user": NICK, "text": f"<@{BOT}> catch up?"},
    ]
    event = _message_event(text=f"<@{BOT}> catch up?", ts=mention_ts)
    _run_message(tmp_path, client, event, posted, join_backfill=2)

    assert len(posted.items) == 1
    body = posted.items[0]["json"]["content"]
    assert "thread before this mention — 2 earlier messages" in body
    assert "early one" not in body
    assert "early two" not in body
    assert "Nick Jalbert: late one" in body
    assert "Nick Jalbert: late two" in body
    assert "catch up?" in body
    # First page is oldest (parent + early one + early two at fetch=3);
    # a second page is required to reach the two replies before the mention.
    assert len(client.replies_calls) >= 2
    assert client.replies_calls[0]["cursor"] in (None, "")
    assert client.replies_calls[0]["limit"] == 3
    assert client.replies_calls[1]["cursor"]


def test_already_active_thread_does_not_backfill(tmp_path, posted):
    threads = ActiveThreads(tmp_path / "pre-threads.json")
    threads.touch(CHAN, PARENT)
    client = _FakeClient()
    client.replies_messages = [
        {"ts": PARENT, "user": NICK, "text": "old context"},
    ]
    event = _message_event(text=f"<@{BOT}> ping")
    _run_message(tmp_path, client, event, posted, threads=threads)

    assert len(posted.items) == 1
    body = posted.items[0]["json"]["content"]
    assert "thread before this mention" not in body
    assert "old context" not in body
    assert client.replies_calls == []


def test_top_level_mention_does_not_backfill(tmp_path, posted):
    client = _FakeClient()
    event = _message_event(
        text=f"<@{BOT}> hello",
        ts="111.500",
        thread_ts=None,
    )
    _run_message(tmp_path, client, event, posted)

    assert len(posted.items) == 1
    assert "thread before this mention" not in posted.items[0]["json"]["content"]
    assert client.replies_calls == []


def test_join_backfill_failure_still_delivers_mention(tmp_path, posted):
    client = _FakeClient()
    client.replies_exc = True
    event = _message_event(text=f"<@{BOT}> still there?")
    _run_message(tmp_path, client, event, posted)

    assert len(posted.items) == 1
    body = posted.items[0]["json"]["content"]
    assert "still there?" in body
    assert "thread before this mention" not in body


def test_join_backfill_zero_skips_lookup(tmp_path, posted):
    client = _FakeClient()
    event = _message_event(text=f"<@{BOT}> hi")
    _run_message(tmp_path, client, event, posted, join_backfill=0)

    assert len(posted.items) == 1
    assert client.replies_calls == []
    assert "thread before this mention" not in posted.items[0]["json"]["content"]


def test_dm_does_not_backfill(tmp_path, posted):
    client = _FakeClient()
    event = _message_event(
        text="hello",
        ts="111.500",
        thread_ts=None,
        channel=DM,
        event_type="message",
        channel_type="im",
    )
    _run_message(tmp_path, client, event, posted)

    assert len(posted.items) == 1
    assert client.replies_calls == []


def test_join_backfill_timeouts_share_one_worker(tmp_path, posted, monkeypatch):
    """Nick #108: do not queue stale conversations.replies after a timeout.

    One in-flight backfill lookup; later first mentions fail open
    immediately instead of submitting more work. Observe pool.submit
    counts (not replies_calls at start-of-call) so queued-but-unstarted
    lookups still fail the test. Wait until the first slow call finishes
    before asserting no second call started.
    """
    monkeypatch.setattr(inbound, "JOIN_BACKFILL_TIMEOUT", 0.05)
    client = _FakeClient()
    client.replies_delay = 0.8
    client.replies_messages = [
        {"ts": PARENT, "user": NICK, "text": "stale context"},
    ]
    cfg = _cfg(tmp_path, join_backfill=2)
    threads = ActiveThreads(cfg.state_dir / "threads.json")
    ib = Inbound(cfg, _FakeApp(client), BOT, threads)
    logger = logging.getLogger("test")
    submits: list[object] = []
    orig_submit = ib._lookup_pool.submit

    def counting_submit(*args, **kwargs):
        submits.append(args)
        return orig_submit(*args, **kwargs)

    ib._lookup_pool.submit = counting_submit  # type: ignore[method-assign]
    try:
        t0 = time.time()
        for i in range(5):
            parent = f"300.{i:03d}"
            ts = f"301.{i:03d}"
            ib._on_event(
                _message_event(
                    text=f"<@{BOT}> ping {i}",
                    ts=ts,
                    thread_ts=parent,
                ),
                logger,
            )
        ib._on_event(
            {
                "type": "message",
                "user": NICK,
                "text": "hello after burst",
                "channel": DM,
                "ts": "400.000",
                "channel_type": "im",
            },
            logger,
        )
        deadline = t0 + 3
        while time.time() < deadline and len(posted.items) < 6:
            time.sleep(0.02)
        elapsed = time.time() - t0
        assert len(posted.items) == 6, posted.items
        # Five 2s waits would be 10s; one 50ms timeout plus delivery is far less.
        assert elapsed < 1.0, elapsed
        assert "hello after burst" in posted.items[-1]["json"]["content"]
        for item in posted.items[:-1]:
            body = item["json"]["content"]
            assert "ping" in body
            assert "thread before this mention" not in body
            assert "stale context" not in body
        # Submissions are counted at pool.submit, so a queued second lookup
        # fails this even before conversations.replies starts. Then wait out
        # the first slow call so a queued worker would have started.
        assert len(submits) == 1, len(submits)
        time.sleep(client.replies_delay + 0.15)
        assert client.max_live == 1
        assert len(client.replies_calls) == 1
        assert len(submits) == 1, len(submits)
    finally:
        ib.stop()
        ib._worker.join(timeout=1)


class _RefusedResponse:
    """A 409 from the web API: the mind's `chat send` refused the message."""

    status_code = 409
    text = '{"detail":{"message":"refusing to send: this exact message already went"}}'

    def json(self):
        return {"detail": {"message": "refusing to send: this exact message already went"}}

    def raise_for_status(self):
        raise httpx.HTTPStatusError(
            "409", request=httpx.Request("POST", "http://headlong.test/chat"), response=self  # type: ignore[arg-type]
        )


def _dm_message(text="great", is_peer=False):
    return inbound.InboundMessage(
        "slack-U123-D123", "U123", "D123", None, "1788451200.123456", text, is_peer=is_peer
    )


def test_refused_delivery_is_not_retried_and_posts_no_error(monkeypatch):
    """A 409 is the mind saying no on purpose. On 2026-09-21 the bridge retried
    three times, posted 'couldn't reach my mind' 22 times, and the peers
    answered each other's error text in a loop."""
    posts = []
    error_posts = []

    class Client:
        def chat_getPermalink(self, **_kwargs):
            return {}

        def chat_postMessage(self, **kwargs):
            error_posts.append(kwargs)

    monkeypatch.setattr(
        inbound.httpx,
        "post",
        lambda url, json, timeout: posts.append(json) or _RefusedResponse(),
    )
    monkeypatch.setattr(inbound.time, "sleep", lambda _s: (_ for _ in ()).throw(AssertionError("slept")))

    bridge = make_inbound(Client())
    bridge._deliver(_dm_message())

    assert len(posts) == 1, "a refusal is final: no retry"
    assert error_posts == [], "no bridge error is posted for a refusal"


def test_other_failures_still_retry_and_post_the_error(monkeypatch):
    posts = []
    error_posts = []

    class Client:
        def chat_getPermalink(self, **_kwargs):
            return {}

        def chat_postMessage(self, **kwargs):
            error_posts.append(kwargs)

    def down(url, json, timeout):
        posts.append(json)
        raise httpx.ConnectError("connection refused")

    monkeypatch.setattr(inbound.httpx, "post", down)
    monkeypatch.setattr(inbound.time, "sleep", lambda _s: None)

    bridge = make_inbound(Client())
    bridge._deliver(_dm_message())

    assert len(posts) == inbound.DELIVERY_ATTEMPTS
    assert len(error_posts) == 1
    assert error_posts[0]["text"] == inbound.DELIVERY_ERROR_TEXT


def test_peer_bridge_error_text_is_not_forwarded(monkeypatch):
    posts = []

    class Client:
        def chat_getPermalink(self, **_kwargs):
            return {}

    monkeypatch.setattr(
        inbound.httpx,
        "post",
        lambda url, json, timeout: posts.append(json) or OkResponse(),
    )
    bridge = make_inbound(Client())
    bridge._deliver(_dm_message(inbound.DELIVERY_ERROR_TEXT, is_peer=True))
    assert posts == [], "the other bridge's error string never reaches the mind"

    bridge._deliver(_dm_message(inbound.DELIVERY_ERROR_TEXT, is_peer=False))
    assert len(posts) == 1, "a person quoting the error text is still delivered"
