"""The inbound gate: DM-only, admin commands, allowlist, delivery."""

import httpx
import pytest

from headlong_telegram import inbound as inbound_mod
from headlong_telegram.api import Bot
from headlong_telegram.allowlist import Allowlist
from headlong_telegram.config import Config
from headlong_telegram.inbound import Inbound

ADMIN = 100


class FakeBot:
    def __init__(self):
        self.sent = []  # (chat_id, text)
        self.left = []

    def send_message(self, chat_id, text, html=False):
        self.sent.append((chat_id, text))

    def leave_chat(self, chat_id):
        self.left.append(chat_id)


@pytest.fixture
def bridge(tmp_path, monkeypatch):
    identity_dir = tmp_path / ".identities" / "audel"
    identity_dir.mkdir(parents=True)
    state_dir = tmp_path / "state"
    state_dir.mkdir()
    cfg = Config(
        serve_root=tmp_path,
        identity="audel",
        identity_dir=identity_dir,
        bot_token="t",
        admin_id=ADMIN,
        web_url="http://web.test",
        state_dir=state_dir,
    )
    bot = FakeBot()
    posts = []

    def fake_post(url, json=None, timeout=None):
        posts.append((url, json))
        return httpx.Response(200, request=httpx.Request("POST", url))

    monkeypatch.setattr(inbound_mod.httpx, "post", fake_post)
    ib = Inbound(cfg, bot, Allowlist(state_dir / "allowlist.json"))
    return ib, bot, posts


def dm(user_id, text, name="Dana"):
    return {
        "message": {
            "chat": {"id": user_id, "type": "private"},
            "from": {"id": user_id, "first_name": name},
            "text": text,
        }
    }


def test_group_message_is_dropped_and_left(bridge):
    ib, bot, posts = bridge
    ib._handle(
        {
            "message": {
                "chat": {"id": -100123, "type": "supergroup"},
                "from": {"id": 7, "first_name": "Dana"},
                "text": "hi all",
            }
        }
    )
    assert bot.left == [-100123]
    assert posts == []


def test_stranger_is_silent_but_admin_prompted_once(bridge):
    ib, bot, posts = bridge
    ib._handle(dm(7, "let me in"))
    ib._handle(dm(7, "hello?"))
    assert posts == []
    admin_prompts = [t for c, t in bot.sent if c == ADMIN]
    assert len(admin_prompts) == 1
    assert "/approve 7" in admin_prompts[0]
    assert not any(c == 7 for c, _ in bot.sent)  # never reply to strangers


def test_approve_flow_end_to_end(bridge):
    ib, bot, posts = bridge
    ib._handle(dm(7, "hi"))
    ib._handle(dm(ADMIN, "/approve 7"))
    ib._handle(dm(7, "hello Audel"))
    assert len(posts) == 1
    url, body = posts[0]
    assert url.endswith("/api/identities/.identities~audel/chat")
    assert body["from_name"] == "telegram-7-7"
    assert "hello Audel" in body["content"]
    assert "chat reply telegram-7-7" in body["content"]
    assert (7, "You're approved — say hi and I'll pass it on.") in bot.sent


def test_admin_commands_never_reach_mind_log(bridge):
    ib, bot, posts = bridge
    for text in ("/list", "/approve 9", "/revoke 9", "/deny 8", "/help"):
        ib._handle(dm(ADMIN, text))
    assert posts == []


def test_admin_plain_text_goes_to_identity(bridge):
    ib, bot, posts = bridge
    ib._handle(dm(ADMIN, f"/approve {ADMIN}"))
    ib._handle(dm(ADMIN, "morning, Audel"))
    assert len(posts) == 1
    assert posts[0][1]["from_name"] == f"telegram-{ADMIN}-{ADMIN}"


def test_media_and_bots_are_dropped(bridge):
    ib, bot, posts = bridge
    ib.allowlist.approve(7)
    ib._handle({"message": {"chat": {"id": 7, "type": "private"},
                            "from": {"id": 7}, "sticker": {}}})
    ib._handle({"message": {"chat": {"id": 7, "type": "private"},
                            "from": {"id": 7, "is_bot": True}, "text": "beep"}})
    assert posts == []


def _dm_with_msg_id(user_id, text, msg_id, name="Dana"):
    """Like dm() but includes a message_id (as Telegram always does)."""
    return {
        "message": {
            "message_id": msg_id,
            "chat": {"id": user_id, "type": "private"},
            "from": {"id": user_id, "first_name": name},
            "text": text,
        }
    }


def test_duplicate_message_id_is_dropped(bridge):
    """A client retry that re-delivers the same message_id must not double-post."""
    ib, bot, posts = bridge
    ib.allowlist.approve(7)
    ib._handle(_dm_with_msg_id(7, "hello", msg_id=500))
    ib._handle(_dm_with_msg_id(7, "hello", msg_id=500))
    assert len(posts) == 1
    assert posts[0][1]["content"].endswith("hello")


def test_same_msg_id_from_different_users_is_delivered(bridge):
    """message_id is per-chat; the same id from two users is two messages."""
    ib, bot, posts = bridge
    ib.allowlist.approve(7)
    ib.allowlist.approve(8)
    ib._handle(_dm_with_msg_id(7, "hi", msg_id=600))
    ib._handle(_dm_with_msg_id(8, "hey", msg_id=600, name="Eve"))
    assert len(posts) == 2


def test_same_text_new_msg_id_is_delivered(bridge):
    """The same text sent twice as distinct messages is delivered twice."""
    ib, bot, posts = bridge
    ib.allowlist.approve(7)
    ib._handle(_dm_with_msg_id(7, "ok", msg_id=503))
    ib._handle(_dm_with_msg_id(7, "ok", msg_id=504))
    assert len(posts) == 2


def test_poll_loop_survives_a_malformed_api_response(tmp_path, monkeypatch):
    """A non-JSON reply must reach the loop's retry branch, not end the loop.

    Driven through a real Bot rather than FakeBot: the failure lives in how
    Bot._call surfaces the error, which a fake bot cannot reproduce.
    """
    identity_dir = tmp_path / ".identities" / "audel"
    identity_dir.mkdir(parents=True)
    state_dir = tmp_path / "state"
    state_dir.mkdir()
    cfg = Config(
        serve_root=tmp_path,
        identity="audel",
        identity_dir=identity_dir,
        bot_token="t",
        admin_id=ADMIN,
        web_url="http://web.test",
        state_dir=state_dir,
    )

    bot = Bot("t")
    bot._client = httpx.Client(
        transport=httpx.MockTransport(
            lambda request: httpx.Response(502, text="<html>502 Bad Gateway</html>")
        )
    )

    slept = []
    monkeypatch.setattr(inbound_mod.time, "sleep", lambda s: slept.append(s))

    ib = Inbound(cfg, bot, Allowlist(state_dir / "allowlist.json"))
    calls = {"n": 0}

    def should_stop():
        calls["n"] += 1
        return calls["n"] > 1  # one failing poll, then stop

    ib.run(should_stop)  # must return, not raise
    assert slept == [5]


def test_refused_delivery_is_not_retried_and_posts_no_error(bridge, monkeypatch):
    """A 409 is the mind's `chat send` refusing on purpose (a repeat, a bad
    target): retrying cannot help and 'couldn't reach my mind' is untrue."""
    ib, bot, posts = bridge
    ib.allowlist.approve(7)
    calls = []

    def refused(url, json=None, timeout=None):
        calls.append(json)
        return httpx.Response(
            409, request=httpx.Request("POST", url), json={"detail": {"message": "refusing"}}
        )

    monkeypatch.setattr(inbound_mod.httpx, "post", refused)
    monkeypatch.setattr(inbound_mod.time, "sleep", lambda _s: None)
    ib._handle(dm(7, "great"))
    assert len(calls) == 1
    assert bot.sent == []


def test_other_failures_still_retry_and_post_the_error(bridge, monkeypatch):
    ib, bot, posts = bridge
    ib.allowlist.approve(7)
    calls = []

    def down(url, json=None, timeout=None):
        calls.append(json)
        return httpx.Response(503, request=httpx.Request("POST", url))

    monkeypatch.setattr(inbound_mod.httpx, "post", down)
    monkeypatch.setattr(inbound_mod.time, "sleep", lambda _s: None)
    ib._handle(dm(7, "great"))
    assert len(calls) == inbound_mod.DELIVERY_ATTEMPTS
    assert bot.sent == [(7, inbound_mod.DELIVERY_ERROR_TEXT)]
