"""Discover shellm identity directories under a serve root.

An identity dir is any directory containing an info.txt with a
root_trajectory= line (see e.g. .identities/<name>/ or
improve/generations/gen-NNN/identities/<run>/).
"""

import logging
from dataclasses import dataclass
from pathlib import Path

logger = logging.getLogger(__name__)

MAX_DEPTH = 6
# Directory names that ARE the identities root. A symlink with one of these
# names directly under the serve root is followed one level (the box keeps
# its identities outside the checkout and links them back here, layer 0 of
# design/runtime_isolation.md); every other symlink is still a candidate
# identity at most, never a path the walk recurses through.
IDENTITIES_ROOT_NAMES = {".identities", "identities"}
PRUNE_DIRS = {
    "trajectories",
    "workdir",
    "workdirs",
    "blobs",
    "run",
    "node_modules",
    ".git",
    ".shellm",
    ".headlong",
    "memories",
    "skills",
    "kernel",
    "thinkers",
    "static",
    "build",
}


@dataclass
class IdentityInfo:
    id: str  # root-relative path with "/" -> "~"
    name: str
    path: Path  # absolute identity dir
    path_rel: str
    created: str | None
    root_trajectory: str | None
    group: str  # parent dir relative to root, e.g. ".identities", "improve/generations/gen-001/identities"


def _parse_info_txt(path: Path) -> dict[str, str]:
    fields: dict[str, str] = {}
    try:
        for line in path.read_text().splitlines():
            if "=" in line:
                key, _, value = line.partition("=")
                fields[key.strip()] = value.strip()
    except OSError:
        pass
    return fields


def identity_id_for(rel: str) -> str:
    return rel.replace("/", "~")


def scan_identities(root: Path) -> list[IdentityInfo]:
    """Walk root for identity dirs (info.txt with root_trajectory).

    A symlinked directory is considered as an identity candidate itself —
    state kept on another volume, `.identities/ada -> /mnt/headlong/current` —
    but the walk never recurses THROUGH a symlink, so a link out to a large
    tree cannot drag the scan across the host. The identity keeps the link's
    own id (the id the bridges construct); a link that resolves to an
    identity found as a real directory (`.identities/default -> audel`) is an
    alias, not a second identity, and is skipped.
    """
    found: list[IdentityInfo] = []
    link_candidates: list[Path] = []

    def add_identity(directory: Path, fields: dict[str, str]) -> None:
        rel = directory.relative_to(root).as_posix()
        group = str(Path(rel).parent) if rel != "." else "."
        found.append(
            IdentityInfo(
                id=identity_id_for(rel),
                name=fields.get("name", directory.name),
                path=directory,
                path_rel=rel,
                created=fields.get("created"),
                root_trajectory=fields.get("root_trajectory"),
                group=group,
            )
        )

    def walk(directory: Path, depth: int) -> None:
        info_txt = directory / "info.txt"
        if info_txt.is_file():
            fields = _parse_info_txt(info_txt)
            if "root_trajectory" in fields:
                add_identity(directory, fields)
                return  # identity dirs don't nest
        if depth >= MAX_DEPTH:
            return
        try:
            children = sorted(directory.iterdir())
        except OSError:
            return
        for child in children:
            if not child.is_dir() or child.name in PRUNE_DIRS:
                continue
            if child.is_symlink():
                if depth == 0 and child.name in IDENTITIES_ROOT_NAMES and not (child / "info.txt").is_file():
                    # The identities root itself, linked out of the checkout.
                    # Walk it by its link path so ids and paths keep the
                    # familiar `.identities/<name>` shape; children that are
                    # links are still only candidates.
                    walk(child, depth + 1)
                else:
                    link_candidates.append(child)
            else:
                walk(child, depth + 1)

    walk(root, 0)

    seen: set[Path] = set()
    for identity in found:
        try:
            seen.add(identity.path.resolve())
        except OSError:
            pass
    for link in sorted(link_candidates):
        try:
            target = link.resolve(strict=True)
        except OSError:
            continue  # dangling or unresolvable
        if target in seen:
            continue  # alias of an identity already found (e.g. `default`)
        fields = _parse_info_txt(link / "info.txt")
        if "root_trajectory" not in fields:
            continue
        seen.add(target)
        add_identity(link, fields)
    return found


def resolve_identity(root: Path, identity_id: str) -> IdentityInfo:
    """Resolve an identity id strictly via a fresh scan (never as a raw path).

    An id that names a symlink to a scanned identity resolves to that
    identity: the scan deduplicates aliases (`.identities/default -> audel`,
    or a link whose target lives elsewhere under the root), but the bridges
    construct their id from the link they were configured with, and that
    spelling has to keep working. The alias is only ever compared against
    identities the scan itself produced, never served as a raw path.
    """
    identities = scan_identities(root)
    for identity in identities:
        if identity.id == identity_id:
            return identity
    rel = identity_id.replace("~", "/")
    if ".." not in Path(rel).parts:
        candidate = root / rel
        if candidate.is_symlink():
            try:
                target = candidate.resolve(strict=True)
            except OSError:
                raise KeyError(identity_id) from None
            for identity in identities:
                try:
                    if identity.path.resolve() == target:
                        return identity
                except OSError:
                    continue
    raise KeyError(identity_id)


def find_root_traj_dir(identity: IdentityInfo) -> Path | None:
    """Locate the mind log's trajectory dir for an identity."""
    traj_root = identity.path / "trajectories"
    if not traj_root.is_dir():
        return None
    root_id = identity.root_trajectory or ""
    if root_id:
        matches = sorted(traj_root.glob(f"{root_id[:8]}-*"))
        for match in matches:
            if (match / "trajectory.jsonl").is_file():
                return match
    # Fallback: any dir whose trajectory.jsonl exists
    for candidate in sorted(traj_root.iterdir()):
        if (candidate / "trajectory.jsonl").is_file():
            return candidate
    return None
