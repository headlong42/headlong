from headlong_telegram.filepayload import CAPTION_MAX, file_payload, file_signature


def test_plain_text_is_not_a_file():
    assert file_payload({"type": "message", "content": "hello"}) is None


def test_filename_stamps_a_document():
    payload = file_payload({"filename": "note.txt", "content": "hi"})
    assert payload is not None
    assert payload["filename"] == "note.txt"
    assert payload["content"] == "hi"
    assert payload["as_photo"] is False
    assert payload["caption"] is None


def test_content_b64_roundtrips_png_bytes():
    import base64
    png = b"\x89PNG\r\n\x1a\n" + b"rest"
    payload = file_payload({
        "filename": "fig.png",
        "content_b64": base64.b64encode(png).decode("ascii"),
    })
    assert payload is not None
    assert payload["content"] == png
    assert payload["as_photo"] is True


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
    payload = file_payload({
        "filename": "a.txt", "content": "x", "caption": "c" * 2000,
    })
    assert payload is not None
    assert payload["caption"] == "c" * CAPTION_MAX

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
        "content": "chat reply telegram-1-2 secret notes",
        "caption": "chat reply telegram-1-2 look",
    })
    assert payload is not None
    assert payload["content"] == "secret notes"
    assert payload["caption"] == "look"


def test_jpeg_uses_photo():
    import base64
    jpeg = b"\xff\xd8\xff" + b"rest"
    payload = file_payload({
        "filename": "shot.jpg",
        "content_b64": base64.b64encode(jpeg).decode("ascii"),
    })
    assert payload is not None
    assert payload["content"] == jpeg
    assert payload["as_photo"] is True


def test_text_content_is_never_a_photo():
    payload = file_payload({"filename": "fig.png", "content": "not-bytes"})
    assert payload is not None
    assert payload["as_photo"] is False


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


def test_file_signature_is_filename_plus_content_hash():
    same = file_signature("note.txt", b"aaa")
    assert same == file_signature("note.txt", "aaa")
    assert same != file_signature("note.txt", b"bbb")
    assert same != file_signature("other.txt", b"aaa")


def test_non_string_content_is_decode_error():
    payload = file_payload({
        "filename": "bad.bin",
        "content": {"x": "y"},
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
