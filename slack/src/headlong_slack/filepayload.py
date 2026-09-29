"""Detect file-bearing mind-log steps for Slack outbound.

`chat send-file` stamps `filename` on the message step. Binary files
travel in `content_b64` (standard base64) because JSON cannot hold raw
bytes; text may sit in `content`. Outbound uploads the decoded bytes
via files_upload_v2 rather than stuffing them into chat_postMessage.
"""

from __future__ import annotations

import base64
import binascii
from pathlib import Path
from typing import Any


class DecodeError(Exception):
    """content_b64 was present but empty or not strict standard base64."""


def _content(step: dict[str, Any]) -> bytes | str | None:
    if "content_b64" in step:
        b64 = step.get("content_b64")
        if not isinstance(b64, str) or not b64:
            raise DecodeError("empty content_b64")
        try:
            raw = base64.b64decode(b64, validate=True)
        except binascii.Error:
            raise DecodeError("invalid base64")
        if not raw:
            raise DecodeError("decoded to empty")
        return raw
    content = step.get("content")
    if isinstance(content, str) and content:
        return content
    return None


def file_payload(step: dict[str, Any]) -> dict[str, Any] | None:
    """Return upload kwargs, or None if this step is ordinary text.

    A file step is one with an explicit `filename` field. The `file`
    alias is not accepted: an ordinary message that happens to carry
    that key must stay a chat_postMessage. Content is leak-filtered so a
    stray `chat reply` in a caption cannot re-trigger the agent.

    If `content_b64` is present but not strict base64 (or decodes to
    empty), the returned dict has `content` None and `decode_error`
    True so outbound can fail loudly instead of falling through to
    chat_postMessage.
    """
    from .slackfmt import strip_leaked_command

    raw_name = step.get("filename")
    if not isinstance(raw_name, str) or not raw_name.strip():
        return None
    filename = Path(raw_name).name
    if not filename or filename in {".", ".."}:
        return None

    decode_error = False
    try:
        content = _content(step)
    except DecodeError:
        content = None
        decode_error = True
    if content is None and not decode_error:
        return None
    if isinstance(content, str):
        content = strip_leaked_command(content)

    caption = step.get("caption")
    if caption is None or caption == "":
        caption_out = None
    else:
        caption_out = strip_leaked_command(str(caption))[:1024] or None

    return {
        "filename": filename,
        "content": content,
        "caption": caption_out,
        "decode_error": decode_error,
    }
