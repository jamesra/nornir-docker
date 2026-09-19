"""Stdlib sqlite catalog and ignore-list mask moves for the slim gallery image."""

from __future__ import annotations

import json
import os
import sqlite3
from pathlib import Path
from typing import Any, Iterable

SAM2_COLUMNS = (
    "sam2PredIou",
    "sam2ObjectScore",
    "sam2Stability",
    "sam2GtIou",
    "sam2Checkpoint",
    "sam2ScoredAt",
)

_CREATE_SQL = """
CREATE TABLE IF NOT EXISTS locations (
    location_id INTEGER PRIMARY KEY,
    z INTEGER NOT NULL,
    structure_id INTEGER,
    structure_label TEXT,
    type_id INTEGER,
    type_name TEXT,
    radius REAL,
    image_key TEXT NOT NULL,
    image_relpath TEXT,
    mask_relpath TEXT,
    ignored INTEGER NOT NULL DEFAULT 0,
    sam2PredIou REAL,
    sam2ObjectScore REAL,
    sam2Stability REAL,
    sam2GtIou REAL,
    sam2Checkpoint TEXT,
    sam2ScoredAt TEXT
)
"""


def sqlite_path(crops: str | os.PathLike[str]) -> Path:
    """Return `{AnnotationCrops}/annotation_crops.sqlite`."""
    return Path(crops) / "annotation_crops.sqlite"


def ignore_path(crops: str | os.PathLike[str]) -> Path:
    """Return `{AnnotationCrops}/ignore.json`."""
    return Path(crops) / "ignore.json"


def connect(crops: str | os.PathLike[str]) -> sqlite3.Connection:
    """Open (and create) the per-volume catalog database."""
    path = sqlite_path(crops)
    path.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(str(path))
    connection.row_factory = sqlite3.Row
    _ensure_locations_schema(connection)
    return connection


def _ensure_locations_schema(connection: sqlite3.Connection) -> None:
    """Create locations and rename jpeg_relpath on catalogs from JPEG-era exports."""
    connection.execute(_CREATE_SQL)
    columns = {row[1] for row in connection.execute("PRAGMA table_info(locations)")}
    if "jpeg_relpath" in columns and "image_relpath" not in columns:
        connection.execute("ALTER TABLE locations RENAME COLUMN jpeg_relpath TO image_relpath")
        connection.commit()


def load_ignore_ids(crops: str | os.PathLike[str]) -> set[int]:
    """Load ignored location ids from `ignore.json` (a JSON array)."""
    path = ignore_path(crops)
    if not path.is_file():
        return set()
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, list):
        return set()
    ids: set[int] = set()
    for item in payload:
        try:
            ids.add(int(item))
        except (TypeError, ValueError):
            continue
    return ids


def save_ignore_ids(crops: str | os.PathLike[str], ids: Iterable[int]) -> None:
    """Write `ignore.json` as a sorted JSON array of location ids."""
    ordered = sorted({int(item) for item in ids})
    ignore_path(crops).write_text(json.dumps(ordered), encoding="utf-8")


def list_catalog_rows(crops: str | os.PathLike[str]) -> list[dict[str, Any]]:
    """Return all catalog rows as plain dicts."""
    path = sqlite_path(crops)
    if not path.is_file():
        return []
    connection = connect(crops)
    try:
        rows = connection.execute(
            "SELECT * FROM locations ORDER BY z, location_id"
        ).fetchall()
        return [dict(row) for row in rows]
    finally:
        connection.close()


def ignore_location(crops: str | os.PathLike[str], location_id: int) -> bool:
    """Add *location_id* to ignore.json and move its mask. Returns True if listed."""
    ids = load_ignore_ids(crops)
    ids.add(int(location_id))
    save_ignore_ids(crops, ids)
    apply_ignore_moves(crops)
    _set_ignored_flag(crops, int(location_id), ignored=True)
    return True


def restore_location(crops: str | os.PathLike[str], location_id: int) -> bool:
    """Remove *location_id* from ignore.json and move the mask back to `masks/`."""
    location_id = int(location_id)
    ids = load_ignore_ids(crops)
    ids.discard(location_id)
    save_ignore_ids(crops, ids)
    source = _find_mask(Path(crops) / "ignored", location_id)
    if source is not None:
        masks = Path(crops) / "masks"
        masks.mkdir(parents=True, exist_ok=True)
        destination = masks / source.name
        if destination.is_file():
            destination.unlink()
        source.replace(destination)
    _set_ignored_flag(crops, location_id, ignored=False)
    return True


def apply_ignore_moves(crops: str | os.PathLike[str]) -> int:
    """Move ignored masks into `ignored/`, replacing any file already there."""
    output = Path(crops)
    ignored_dir = output / "ignored"
    moved = 0
    for location_id in load_ignore_ids(output):
        source = _find_mask(output / "masks", location_id)
        if source is None:
            continue
        ignored_dir.mkdir(parents=True, exist_ok=True)
        destination = ignored_dir / source.name
        if destination.is_file():
            destination.unlink()
        source.replace(destination)
        moved += 1
    return moved


def _set_ignored_flag(
    crops: str | os.PathLike[str],
    location_id: int,
    *,
    ignored: bool,
) -> None:
    path = sqlite_path(crops)
    if not path.is_file():
        return
    connection = connect(crops)
    try:
        connection.execute(
            "UPDATE locations SET ignored = ?, mask_relpath = ? WHERE location_id = ?",
            [
                1 if ignored else 0,
                _mask_relpath_for_id(crops, location_id, ignored=ignored),
                location_id,
            ],
        )
        connection.commit()
    finally:
        connection.close()


def _mask_relpath_for_id(crops: str | os.PathLike[str], location_id: int, *, ignored: bool) -> str:
    folder = Path(crops) / ("ignored" if ignored else "masks")
    found = _find_mask(folder, location_id)
    if found is not None:
        return str(found.relative_to(crops)).replace("\\", "/")
    return f"{'ignored' if ignored else 'masks'}/{location_id}.png"


def _find_mask(folder: Path, location_id: int) -> Path | None:
    if not folder.is_dir():
        return None
    suffix = f"_{int(location_id)}.png"
    matches = sorted(folder.glob(f"*{suffix}"))
    if not matches:
        return None
    return matches[0]
