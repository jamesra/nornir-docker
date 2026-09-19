"""Slim gallery HTTP: stub identity, ignore 403, path traversal."""

from __future__ import annotations

import json
import sys
import threading
from http.client import HTTPConnection
from pathlib import Path

import pytest

GALLERY_ROOT = Path(__file__).resolve().parents[1]
if str(GALLERY_ROOT) not in sys.path:
    sys.path.insert(0, str(GALLERY_ROOT))

from catalog import connect  # noqa: E402
from identity import OidcIdentity, map_permission_names  # noqa: E402
from server import (  # noqa: E402
    list_registry_names,
    make_server,
    safe_crop_file,
    volume_root,
)

_MIN_PNG = (
    b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01"
    b"\x08\x00\x00\x00\x00:\x7e\x9bU\x00\x00\x00\nIDATx\x9cc\xf8\x0f\x00\x01"
    b"\x01\x01\x00\x1b\xb6\xeeV\x00\x00\x00\x00IEND\xaeB`\x82"
)


def _seed_crops(crops: Path, *, location_id: int = 42) -> None:
    images = crops / "images"
    masks = crops / "masks"
    images.mkdir(parents=True)
    masks.mkdir()
    (images / "RC2_17_D1_X0_Y0.png").write_bytes(_MIN_PNG)
    (masks / f"RC2_17_D1_X0_Y0_{location_id}.png").write_bytes(_MIN_PNG)
    connection = connect(crops)
    connection.execute(
        "INSERT INTO locations (location_id, z, structure_id, structure_label, "
        "type_id, type_name, radius, image_key, image_relpath, mask_relpath, ignored) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)",
        [
            location_id,
            17,
            7,
            "soma",
            1,
            "Cell",
            12.5,
            "RC2_17_D1_X0_Y0",
            "images/RC2_17_D1_X0_Y0.png",
            f"masks/RC2_17_D1_X0_Y0_{location_id}.png",
        ],
    )
    connection.commit()
    connection.close()


@pytest.fixture
def registry(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    registry_path = tmp_path / "gallery-volumes"
    volume = registry_path / "RC2"
    crops = volume / "AnnotationCrops"
    volume.mkdir(parents=True)
    _seed_crops(crops)
    monkeypatch.setenv("GALLERY_VOLUME_DIR", str(registry_path))
    monkeypatch.setenv("GALLERY_IDENTITY_MODE", "stub")
    monkeypatch.setenv("GALLERY_STUB_ROLE", "read")
    monkeypatch.setenv("GALLERY_SESSION_SECRET", "test-secret")
    return registry_path


@pytest.fixture
def httpd(registry: Path) -> tuple[str, int]:
    del registry
    server = make_server("127.0.0.1", 0)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    host, port = server.server_address[:2]
    try:
        yield str(host), int(port)
    finally:
        server.shutdown()
        server.server_close()


def _request(
    httpd: tuple[str, int],
    method: str,
    path: str,
    *,
    body: bytes | None = None,
    headers: dict[str, str] | None = None,
    bearer: str | None = None,
) -> tuple[int, dict]:
    connection = HTTPConnection(httpd[0], httpd[1], timeout=5)
    extra = dict(headers or {})
    if bearer:
        extra["Authorization"] = f"Bearer {bearer}"
    if body is not None:
        extra.setdefault("Content-Type", "application/json")
        extra["Content-Length"] = str(len(body))
    connection.request(method, path, body=body, headers=extra)
    response = connection.getresponse()
    raw = response.read()
    connection.close()
    payload = json.loads(raw.decode("utf-8")) if raw else {}
    return response.status, payload


def test_read_lists_volume_and_catalog(httpd: tuple[str, int]) -> None:
    status, me = _request(httpd, "GET", "/api/me", bearer="read")
    assert status == 200
    assert me["volumes"] == [{"name": "RC2", "permission": "read"}]
    status, catalog = _request(httpd, "GET", "/api/volumes/RC2/catalog", bearer="read")
    assert status == 200
    assert catalog["rows"][0]["location_id"] == 42


def test_read_ignore_is_403(httpd: tuple[str, int]) -> None:
    status, payload = _request(
        httpd,
        "POST",
        "/api/volumes/RC2/ignore",
        body=json.dumps({"location_id": 42}).encode("utf-8"),
        bearer="read",
    )
    assert status == 403
    assert "review" in payload["error"]


def test_review_can_ignore_and_restore(httpd: tuple[str, int], registry: Path) -> None:
    status, payload = _request(
        httpd,
        "POST",
        "/api/volumes/RC2/ignore",
        body=json.dumps({"location_id": 42}).encode("utf-8"),
        bearer="review",
    )
    assert status == 200
    assert payload["ignored"] is True
    crops = registry / "RC2" / "AnnotationCrops"
    assert (crops / "ignored" / "RC2_17_D1_X0_Y0_42.png").is_file()
    status, payload = _request(
        httpd,
        "POST",
        "/api/volumes/RC2/restore",
        body=json.dumps({"location_id": 42}).encode("utf-8"),
        bearer="review",
    )
    assert status == 200
    assert payload["ignored"] is False
    assert (crops / "masks" / "RC2_17_D1_X0_Y0_42.png").is_file()


def test_path_traversal_rejected(httpd: tuple[str, int], registry: Path) -> None:
    status, payload = _request(
        httpd,
        "GET",
        "/api/volumes/RC2/file?path=../../etc/passwd",
        bearer="read",
    )
    assert status == 400
    status, payload = _request(
        httpd,
        "GET",
        "/api/volumes/../RC2/catalog",
        bearer="read",
    )
    assert status == 404
    with pytest.raises(ValueError):
        safe_crop_file(registry / "RC2" / "AnnotationCrops", "../AnnotationCrops/images/x.jpg")
    with pytest.raises(ValueError):
        volume_root(registry, "..")
    assert list_registry_names(registry) == ["RC2"]


def test_spa_hides_review_controls_without_review() -> None:
    css = (GALLERY_ROOT / "static" / "app.css").read_text(encoding="utf-8")
    assert "body.no-review button.trash" in css
    js = (GALLERY_ROOT / "static" / "app.js").read_text(encoding="utf-8")
    assert "no-review" in js
    html = (GALLERY_ROOT / "static" / "index.html").read_text(encoding="utf-8")
    assert 'class="jpeg"' in html or "jpeg" in js


def test_dockerfile_has_no_nornir() -> None:
    lines = [
        line
        for line in (GALLERY_ROOT / "Dockerfile").read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    text = "\n".join(lines).lower()
    assert "nornir-buildmanager" not in text
    assert "imageregistration" not in text
    assert "cupy" not in text
    assert "torch" not in text
    assert "refresh-export" not in text
    assert "pip install" not in text


def test_map_permission_names_read_vs_review() -> None:
    assert map_permission_names(["Read"]) == "read"
    assert map_permission_names(["Read", "Review"]) == "review"
    assert map_permission_names(["Admin"]) is None


def test_oidc_maps_identity_api_volumes() -> None:
    calls: list[str] = []

    def http_json(url: str, **kwargs: object) -> object:
        del kwargs
        calls.append(url)
        if url.endswith("/connect/token"):
            return {"access_token": "tok"}
        if url.endswith("/connect/userinfo"):
            return {"sub": "u1", "name": "Ada"}
        if url.endswith("/api/volumes"):
            return [
                {"name": "RC2", "permissions": ["Read", "Review"]},
                {"name": "SKIPME", "permissions": ["Read"]},
            ]
        raise AssertionError(url)

    oidc = OidcIdentity(
        {
            "GALLERY_OIDC_AUTHORITY": "https://identity.codepharm.net:5001",
            "GALLERY_IDENTITY_API": "https://identity.codepharm.net:6001",
            "GALLERY_OIDC_CLIENT_ID": "gallery",
        },
        http_json=http_json,
    )
    principal = oidc.complete_login("code", "http://127.0.0.1:8090/callback", ["RC2"])
    assert principal.display_name == "Ada"
    assert principal.grants == {"RC2": "review"}
    assert any("identity.codepharm.net:5001" in url for url in calls)
    assert any("identity.codepharm.net:6001" in url for url in calls)


def test_oidc_login_url_points_at_authority() -> None:
    oidc = OidcIdentity(
        {
            "GALLERY_OIDC_AUTHORITY": "https://identity.codepharm.net:5001",
            "GALLERY_OIDC_CLIENT_ID": "gallery",
        }
    )
    url = oidc.login_url("http://127.0.0.1:8090/callback", "state-1")
    assert url.startswith("https://identity.codepharm.net:5001/connect/authorize?")
    assert "client_id=gallery" in url
