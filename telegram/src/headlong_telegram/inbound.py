"""Telegram updates -> mind log.

A single long-poll loop over getUpdates. Every update passes through the
same gate, in order: DM-only (anything else is dropped and group chats are
left), then admin commands, then the allowlist. Only text from approved
senders is POSTed to the local shellm web API, which appends it to the
identity's trajectory via `bin/chat`.

The getUpdates offset is persisted after each batch, so delivery is
at-least-once across restarts; the bridge deduplicates by message_id, so
client retries and replays do not double-post.
"""

from __future__ import annotations

import logging
import time
from typing import Any

import httpx

from . import naming, tgfmt
from .allowlist import Allowlist
from .api import ApiError, Bot
from .config import Config
from .state import Offset

log = logging.getLogger(__name__)

DELIVERY_ATTEMPTS = 3
DELIVERY_ERROR_TEXT = (
    "(bridge error: I couldn't reach my mind just now — please try again in a bit)"
)

ADMIN_HELP = (
    "headlong telegram bridge admin commands:\n"
    "/approve <id> — let this user talk to the identity\n"
    "/deny <id> — silence a pending request for good\n"
    "/revoke <id> — remove an approved user\n"
    "/list — show approved + pending users\n"
    "Anything else you type here goes to the identity as a normal message."
)


class Inbound:
    def __init__(self, cfg: Config, bot: Bot, allowlist: Allowlist):
        self.cfg = cfg
        self.bot = bot
        self.allowlist = allowlist
        self.offset = Offset(cfg.state_dir / "update_offset")
        self._chat_url = f"{cfg.web_url}/api/identities/{cfg.identity_api_id}/chat"
        # Dedup: Telegram delivers at-least-once; a client retry can produce
        # two updates (different update_ids) for the same message. Drop
        # duplicates by (user, message_id) — message_id alone is only
        # unique within one chat, so two users may share the same id.
        self._seen_msg_ids: dict[tuple[int, int], float] = {}

    # -- poll loop -----------------------------------------------------------

    def run(self, should_stop=lambda: False) -> None:
        while not should_stop():
            try:
                updates = self.bot.get_updates(self.offset.value)
            except (ApiError, httpx.HTTPError):
                # Includes 409: another poller holds this token. Keep retrying
                # (and complaining) — the conflict is worth noticing in logs.
                log.exception("getUpdates failed; retrying in 5s")
                time.sleep(5)
                continue
            for update in updates:
                try:
                    self._handle(update)
                except Exception:
                    log.exception("failed handling update %s", update.get("update_id"))
                self.offset.advance(update["update_id"] + 1)

    # -- the gate ------------------------------------------------------------

    def _handle(self, update: dict[str, Any]) -> None:
        message = update.get("message")
        if not message:
            return
        chat = message.get("chat", {})
        sender = message.get("from", {})
        user_id = sender.get("id")
        if chat.get("type") != "private":
            # DM-only pilot: never sit in a group, where the allowlist can't
            # gate who is in the room.
            chat_id = chat.get("id")
            log.warning("dropping non-DM message in chat %s; leaving", chat_id)
            if chat_id is not None:
                try:
                    self.bot.leave_chat(chat_id)
                except ApiError:
                    pass
            return
        if not user_id or sender.get("is_bot"):
            return
        text = message.get("text") or ""
        if not text:
            return  # text-only pilot: media, stickers, etc. are dropped

        # Dedup: drop if we have already seen this (user, message_id).
        # Telegram retries can produce two updates with different
        # update_ids for the same message.
        now = time.monotonic()
        msg_id = message.get("message_id")
        if msg_id is not None:
            dedup_key = (user_id, msg_id)
            if dedup_key in self._seen_msg_ids:
                log.info("dropping duplicate message_id %s from user %s", msg_id, user_id)
                return
            self._seen_msg_ids[dedup_key] = now
            cutoff = now - 300
            self._seen_msg_ids = {
                k: v for k, v in self._seen_msg_ids.items() if v > cutoff
            }

        if user_id == self.cfg.admin_id and self._admin_command(text):
            return
        if not self.allowlist.is_approved(user_id):
            self._pending(user_id, sender)
            return
        if text.strip() == "/start":
            self.bot.send_message(chat["id"], "Connected — just type.")
            return
        self._deliver(user_id, chat["id"], sender, text)

    # -- admin commands (intercepted; never reach the mind log) --------------

    def _admin_command(self, text: str) -> bool:
        parts = text.strip().split()
        command = parts[0].lower() if parts else ""
        if command not in ("/approve", "/deny", "/revoke", "/list", "/help", "/start"):
            return False
        reply = ADMIN_HELP
        if command in ("/approve", "/deny", "/revoke"):
            if len(parts) != 2 or not parts[1].isdigit():
                reply = f"usage: {command} <numeric user id>"
            else:
                target = int(parts[1])
                if command == "/approve":
                    self.allowlist.approve(target)
                    reply = f"approved {target}"
                    try:
                        # DM chat id == user id; fails harmlessly until the
                        # user has started the bot.
                        self.bot.send_message(
                            target, "You're approved — say hi and I'll pass it on."
                        )
                    except ApiError:
                        pass
                elif command == "/deny":
                    self.allowlist.deny(target)
                    reply = f"denied {target} (silenced for good)"
                else:
                    reply = (
                        f"revoked {target}"
                        if self.allowlist.revoke(target)
                        else f"{target} wasn't approved"
                    )
        elif command == "/list":
            reply = self.allowlist.summary()
        self.bot.send_message(self.cfg.admin_id, reply)
        return True

    # -- unknown senders -----------------------------------------------------

    def _pending(self, user_id: int, sender: dict[str, Any]) -> None:
        # Silent to the sender: replying would confirm a live bot to whoever
        # is probing it. The admin gets one prompt per sender per day.
        label = tgfmt.sender_label(sender)
        if self.allowlist.note_pending(user_id, label):
            self.bot.send_message(
                self.cfg.admin_id,
                f"{label} (id {user_id}) wants to talk — "
                f"/approve {user_id} or /deny {user_id}",
            )

    # -- delivery ------------------------------------------------------------

    def _deliver(
        self, user_id: int, chat_id: int, sender: dict[str, Any], text: str
    ) -> None:
        content = tgfmt.clean_inbound(text)
        if not content:
            return
        from_name = naming.encode(user_id, chat_id)
        # The reply-to name is spelled out because agent-typed replies (the
        # agentic path, unlike the mechanical fast-reply) must use the full
        # routing key, not the human display name.
        header = (
            f"(Telegram: {tgfmt.sender_label(sender)}"
            f" — reply with: chat reply {from_name})"
        )
        body = {"content": f"{header} {content}", "from_name": from_name}
        for attempt in range(1, DELIVERY_ATTEMPTS + 1):
            try:
                response = httpx.post(self._chat_url, json=body, timeout=30)
                response.raise_for_status()
                return
            except httpx.HTTPStatusError as exc:
                if exc.response.status_code == 409:
                    # The mind's tool refused the message on purpose (a
                    # duplicate or a bad target); it will refuse it again,
                    # and "couldn't reach my mind" would be untrue.
                    log.warning(
                        "chat POST refused for %s: %s", from_name, exc.response.text[:200]
                    )
                    return
                log.warning(
                    "chat POST failed (attempt %d/%d)",
                    attempt,
                    DELIVERY_ATTEMPTS,
                    exc_info=True,
                )
                if attempt < DELIVERY_ATTEMPTS:
                    time.sleep(2 * attempt)
            except httpx.HTTPError:
                log.warning(
                    "chat POST failed (attempt %d/%d)",
                    attempt,
                    DELIVERY_ATTEMPTS,
                    exc_info=True,
                )
                if attempt < DELIVERY_ATTEMPTS:
                    time.sleep(2 * attempt)
        try:
            self.bot.send_message(chat_id, DELIVERY_ERROR_TEXT)
        except ApiError:
            log.exception("failed posting delivery error to telegram")
