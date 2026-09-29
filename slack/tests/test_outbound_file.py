"""Outbound file delivery tests."""

import threading
import base64

from headlong_slack import outbound
from headlong_slack.config import Config


def test_run_delivers_file_steps(tmp_path, monkeypatch):
    """File steps (with filename) are uploaded via files_upload_v2."""
    file_data = b"hello file"
    steps = [
        # File step
        {
            "type": "message", "from": "audel", "to": "slack-C1-U1",
            "source": "chat", "content": "", "filename": "note.txt",
            "content_b64": base64.b64encode(file_data).decode("ascii"),
            "step_id": "aaa"
        },
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    uploaded = []

    class FakeClient:
        def files_upload_v2(self, channel, file, filename, initial_comment=None, thread_ts=None, **kw):
            uploaded.append({"channel": channel, "filename": filename, "content": file.read()})
            return {"ok": True}

    class FakeThreads:
        def touch(self, channel, thread_ts):
            pass

    cfg = Config(
        serve_root=tmp_path, identity="audel", identity_dir=tmp_path,
        bot_token="x", app_token="x", web_url="http://x", state_dir=tmp_path,
        thread_followups=True,
    )
    outbound.run(cfg, FakeClient(), FakeThreads(), threading.Event())

    assert len(uploaded) == 1
    assert uploaded[0]["filename"] == "note.txt"
    assert uploaded[0]["content"] == file_data


def test_run_delivers_file_with_caption(tmp_path, monkeypatch):
    """File steps with caption include it as initial_comment."""
    file_data = b"hello file"
    steps = [
        {
            "type": "message", "from": "audel", "to": "slack-C1-U1",
            "source": "chat", "content": "", "filename": "note.txt",
            "content_b64": base64.b64encode(file_data).decode("ascii"),
            "caption": "here is the file",
            "step_id": "aaa"
        },
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    uploaded = []

    class FakeClient:
        def files_upload_v2(self, channel, file, filename, initial_comment=None, thread_ts=None, **kw):
            uploaded.append({"channel": channel, "filename": filename, "content": file.read(), "comment": initial_comment})
            return {"ok": True}

    class FakeThreads:
        def touch(self, channel, thread_ts):
            pass

    cfg = Config(
        serve_root=tmp_path, identity="audel", identity_dir=tmp_path,
        bot_token="x", app_token="x", web_url="http://x", state_dir=tmp_path,
        thread_followups=True,
    )
    outbound.run(cfg, FakeClient(), FakeThreads(), threading.Event())

    assert len(uploaded) == 1
    assert uploaded[0]["comment"] == "here is the file"


def test_run_handles_decode_error(tmp_path, monkeypatch):
    """Decode errors are logged and a failure notice is sent."""
    steps = [
        {
            "type": "message", "from": "audel", "to": "slack-C1-U1",
            "source": "chat", "content": "", "filename": "note.txt",
            "content_b64": "!!!!",  # invalid base64
            "step_id": "aaa"
        },
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    posted = []

    class FakeClient:
        def chat_postMessage(self, channel, thread_ts, text, unfurl_links=False, **kw):
            posted.append(text)
        def files_upload_v2(self, *a, **kw):
            return {"ok": True}

    class FakeThreads:
        def touch(self, channel, thread_ts):
            pass

    cfg = Config(
        serve_root=tmp_path, identity="audel", identity_dir=tmp_path,
        bot_token="x", app_token="x", web_url="http://x", state_dir=tmp_path,
        thread_followups=True,
    )
    outbound.run(cfg, FakeClient(), FakeThreads(), threading.Event())

    # Should post a failure notice
    assert any("failed to deliver file" in m for m in posted)


def test_run_handles_upload_failure(tmp_path, monkeypatch):
    """Upload failures are caught and a failure notice is sent."""
    file_data = b"hello file"
    steps = [
        {
            "type": "message", "from": "audel", "to": "slack-C1-U1",
            "source": "chat", "content": "", "filename": "note.txt",
            "content_b64": base64.b64encode(file_data).decode("ascii"),
            "step_id": "aaa"
        },
    ]
    monkeypatch.setattr(outbound.mindlog, "find_trajectory", lambda d: tmp_path / "t.jsonl")
    monkeypatch.setattr(outbound.mindlog, "follow", lambda *a, **k: iter(steps))

    posted = []

    class FakeClient:
        def chat_postMessage(self, channel, thread_ts, text, unfurl_links=False, **kw):
            posted.append(text)
        def files_upload_v2(self, *a, **kw):
            raise Exception("upload failed")

    class FakeThreads:
        def touch(self, channel, thread_ts):
            pass

    cfg = Config(
        serve_root=tmp_path, identity="audel", identity_dir=tmp_path,
        bot_token="x", app_token="x", web_url="http://x", state_dir=tmp_path,
        thread_followups=True,
    )
    outbound.run(cfg, FakeClient(), FakeThreads(), threading.Event())

    # Should post a failure notice
    assert any("failed to deliver file" in m for m in posted)
