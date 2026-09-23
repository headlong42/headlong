"""Symlinked identities: the scan and resolver must serve them (issue #66).

An identity reached through a symlink — state on another volume,
`.identities/ada -> /mnt/headlong/current` — was invisible to
scan_identities, so the bridges (which accept the link and construct the id
from it) got a 404 on every message. The scan now considers a symlinked
directory as an identity candidate under the link's own id, without ever
recursing through a symlink, and resolve_identity honors an id that names a
link to a scanned identity.
"""

from pathlib import Path

import pytest

from headlong_web import discovery


def _identity(dir_: Path, name: str) -> Path:
    dir_.mkdir(parents=True)
    (dir_ / "info.txt").write_text(f"name={name}\nroot_trajectory=abc123\n")
    return dir_


def _ids(root: Path) -> list[str]:
    return [i.id for i in discovery.scan_identities(root)]


def test_link_to_an_identity_outside_the_root_is_found(tmp_path: Path) -> None:
    root = tmp_path / "root"
    (root / ".identities").mkdir(parents=True)
    elsewhere = _identity(tmp_path / "volume" / "current", "ada")
    (root / ".identities" / "ada").symlink_to(elsewhere)

    ids = _ids(root)
    assert ".identities~ada" in ids
    resolved = discovery.resolve_identity(root, ".identities~ada")
    assert resolved.path == root / ".identities" / "ada"
    assert resolved.name == "ada"


def test_default_link_is_an_alias_not_a_second_identity(tmp_path: Path) -> None:
    root = tmp_path / "root"
    _identity(root / ".identities" / "audel", "audel")
    (root / ".identities" / "default").symlink_to("audel")

    ids = _ids(root)
    assert ids.count(".identities~audel") == 1
    assert ".identities~default" not in ids
    # ...but the alias id still resolves, to the real identity.
    assert discovery.resolve_identity(root, ".identities~default").id == ".identities~audel"


def test_link_to_an_identity_elsewhere_in_root_resolves_by_link_id(tmp_path: Path) -> None:
    """The issue's second case: the target is scanned under its real path,
    and the bridge's link-derived id must still resolve to it."""
    root = tmp_path / "root"
    _identity(root / "elsewhere" / "ada", "ada")
    (root / ".identities").mkdir()
    (root / ".identities" / "ada").symlink_to(root / "elsewhere" / "ada")

    ids = _ids(root)
    assert "elsewhere~ada" in ids
    assert ids.count("elsewhere~ada") == 1
    assert discovery.resolve_identity(root, ".identities~ada").id == "elsewhere~ada"


def test_dangling_link_is_skipped(tmp_path: Path) -> None:
    root = tmp_path / "root"
    _identity(root / ".identities" / "bo", "bo")
    (root / ".identities" / "ghost").symlink_to("nowhere")

    assert _ids(root) == [".identities~bo"]
    with pytest.raises(KeyError):
        discovery.resolve_identity(root, ".identities~ghost")


def test_scan_never_recurses_through_a_symlink(tmp_path: Path) -> None:
    """A link to a tree that CONTAINS identities is not walked: only a link
    that is itself an identity dir counts. Keeps a link out to a big host
    tree from dragging the scan across it."""
    root = tmp_path / "root"
    (root / ".identities").mkdir(parents=True)
    outside = tmp_path / "outside"
    _identity(outside / "nested" / "deep", "deep")
    (root / ".identities" / "farm").symlink_to(outside)

    assert _ids(root) == []


def test_symlink_cycle_is_safe(tmp_path: Path) -> None:
    root = tmp_path / "root"
    (root / ".identities").mkdir(parents=True)
    (root / ".identities" / "loop").symlink_to(root / ".identities")

    assert _ids(root) == []


def test_two_links_to_one_target_yield_one_identity(tmp_path: Path) -> None:
    root = tmp_path / "root"
    (root / ".identities").mkdir(parents=True)
    elsewhere = _identity(tmp_path / "volume" / "ada", "ada")
    (root / ".identities" / "ada").symlink_to(elsewhere)
    (root / ".identities" / "ada2").symlink_to(elsewhere)

    ids = _ids(root)
    assert ids.count(".identities~ada") == 1
    assert ".identities~ada2" not in ids
    # The second spelling still resolves, as an alias.
    assert discovery.resolve_identity(root, ".identities~ada2").id == ".identities~ada"


def test_traversal_in_an_alias_id_is_rejected(tmp_path: Path) -> None:
    root = tmp_path / "root"
    _identity(root / ".identities" / "bo", "bo")

    with pytest.raises(KeyError):
        discovery.resolve_identity(root, "..~..~etc")


def test_linked_identities_root_is_walked(tmp_path: Path) -> None:
    """The whole .identities root kept outside the checkout and linked back
    (the box layout since 2026-09-15): identities under it are found with
    their usual ids and link-path locations, and a link INSIDE it is still
    only a candidate, never recursed through."""
    root = tmp_path / "root"
    root.mkdir()
    real_root = tmp_path / "var-lib" / "identities"
    _identity(real_root / "harris", "harris")
    (real_root / "default").symlink_to("harris")
    (root / ".identities").symlink_to(real_root)
    # a link inside the root to a tree that must not be walked
    deep = tmp_path / "elsewhere" / "deep"
    _identity(deep / "nested" / "hidden", "hidden")
    (real_root / "trap").symlink_to(deep)

    ids = _ids(root)
    assert ".identities~harris" in ids
    assert ids.count(".identities~harris") == 1
    assert ".identities~default" not in ids
    assert not any("hidden" in i for i in ids)
    resolved = discovery.resolve_identity(root, ".identities~harris")
    assert resolved.path == root / ".identities" / "harris"
    assert discovery.resolve_identity(root, ".identities~default").id == ".identities~harris"


def test_linked_root_that_is_itself_an_identity_stays_a_candidate(tmp_path: Path) -> None:
    root = tmp_path / "root"
    root.mkdir()
    lone = _identity(tmp_path / "solo", "solo")
    (root / ".identities").symlink_to(lone)
    ids = _ids(root)
    assert ids == [".identities"] or ".identities" in ids
