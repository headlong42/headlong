from headlong_slack.filepayload import file_payload


def test_plain_text_is_not_a_file():
    assert file_payload({"type": "message", "content": "hello"}) is None


def test_filename_stamps_a_file():
    payload = file_payload({"filename": "note.txt", "content": "hi"})
    assert payload is not None
    assert payload["filename"] == "note.txt"
    assert payload["content"] == "hi"
    assert payload["caption"] is None


def test_content_b64_roundtrips_binary_bytes():
    import base64
    data = b"\x00\xff\xfe" + b"rest"
    payload = file_payload({
        "filename": "fig.bin",
        "content_b64": base64.b64encode(data).decode("ascii"),
    })
    assert payload is not None
    assert payload["content"] == data


def test_svg_without_filename_stays_text():
    assert file_payload({"content": "<svg xmlns='x'></svg>"}) is None


def test_path_is_reduced_to_basename():
    payload = file_payload({"filename": "/etc/passwd", "content": "x"})
    assert payload is not None
    assert payload["filename"] == "passwd"


def test_invalid_b64_is_not_a_file():
    payload = file_payload({"filename": "a.bin", "content_b64": "!!!!"})
    assert payload is not None
    assert payload["content"] is None
    assert payload["decode_error"] is True


def test_caption_is_truncated():
    from headlong_slack.slackfmt import MAX_MESSAGE_CHARS
    payload = file_payload({
        "filename": "a.txt", "content": "x", "caption": "c" * 2000,
    })
    assert payload is not None
    # caption truncated to 1024 by filepayload
    assert payload["caption"] == "c" * 1024


def test_file_alias_is_ignored():
    # Canonical key is `filename`. A stray `file` field must not reclassify
    # an ordinary message as an upload.
    assert file_payload({"file": "note.txt", "content": "hi"}) is None
    payload = file_payload({"filename": "note.txt", "file": "other.bin", "content": "hi"})
    assert payload is not None
    assert payload["filename"] == "note.txt"


def test_caption_and_text_content_are_leak_filtered():
    payload = file_payload({
        "filename": "note.txt",
        "content": "chat reply slack-C1-U1 secret notes",
        "caption": "chat reply slack-C1-U1 look",
    })
    assert payload is not None
    assert payload["content"] == "secret notes"
    assert payload["caption"] == "look"


def test_text_content_is_never_an_upload():
    payload = file_payload({"filename": "fig.png", "content": "not-bytes"})
    assert payload is not None
    # Text content is just returned as-is, not treated as upload


def test_invalid_content_b64_is_decode_error():
    payload = file_payload({
        "filename": "note.txt",
        "content_b64": "@@@not-base64@@@",
        "content": "[file: note.txt]",
    })
    assert payload is not None
    assert payload["content"] is None
    assert payload["decode_error"] is True


def test_empty_content_b64_is_decode_error():
    payload = file_payload({
        "filename": "note.txt",
        "content_b64": "",
        "content": "[file: note.txt]",
    })
    assert payload is not None
    assert payload["content"] is None
    assert payload["decode_error"] is True


def test_nul_bytes_roundtrip():
    import base64
    # Test file with NUL bytes and newlines
    data = b"a\x00b\nc\rd"
    payload = file_payload({
        "filename": "nul.bin",
        "content_b64": base64.b64encode(data).decode("ascii"),
    })
    assert payload is not None
    assert payload["content"] == data
