"""Slim AnnotationCrops gallery: sqlite read, ignore/restore, no Nornir."""

from __future__ import annotations

import hmac
import json
import os
import posixpath
import re
import secrets
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, unquote, urlparse

from catalog import ignore_location, list_catalog_rows, restore_location
from identity import (
    PERMISSION_READ,
    PERMISSION_REVIEW,
    OidcIdentity,
    Principal,
    StubIdentity,
)

VOLUME_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
FILE_PREFIXES = frozenset({"images", "masks", "ignored"})
STATIC_DIR = Path(__file__).resolve().parent / "static"
SESSION_COOKIE = "gallery_session"


def env_map() -> dict[str, str]:
    """Process environment as a plain str→str map."""
    return {str(key): str(value) for key, value in os.environ.items()}


def registry_dir(environ: dict[str, str] | None = None) -> Path:
    """Folder of volume-root links. Child name is the Identity volume name."""
    mapping = environ or env_map()
    raw = mapping.get("GALLERY_VOLUME_DIR") or "/gallery-volumes"
    return Path(raw)


def identity_mode(environ: dict[str, str] | None = None) -> str:
    mapping = environ or env_map()
    mode = (mapping.get("GALLERY_IDENTITY_MODE") or "stub").strip().lower()
    if mode not in {"stub", "oidc"}:
        return "stub"
    return mode


def viking_template(environ: dict[str, str] | None = None) -> str:
    mapping = environ or env_map()
    return mapping.get("GALLERY_VIKING_URL") or (
        "https://connectomes.utah.edu/connectome/{volume}#locationID={id}"
    )


def session_secret(environ: dict[str, str] | None = None) -> bytes:
    mapping = environ or env_map()
    text = mapping.get("GALLERY_SESSION_SECRET") or "dev-only-not-secret"
    return text.encode("utf-8")


def list_registry_names(registry: Path) -> list[str]:
    """Identity volume names present as registry children. Rejects ``..``."""
    if not registry.is_dir():
        return []
    names: list[str] = []
    for child in sorted(registry.iterdir(), key=lambda path: path.name.lower()):
        if not VOLUME_NAME.fullmatch(child.name):
            continue
        if child.is_dir() or child.is_symlink():
            names.append(child.name)
    return names


def volume_root(registry: Path, name: str) -> Path:
    """Return the volume-root path for a registry child. Name is never a path."""
    if not VOLUME_NAME.fullmatch(name):
        raise ValueError("invalid volume name")
    path = registry / name
    if not path.exists():
        raise FileNotFoundError(name)
    return path


def crops_dir(registry: Path, name: str) -> Path:
    """``{volume-root}/AnnotationCrops`` for a registry child."""
    return volume_root(registry, name) / "AnnotationCrops"


def safe_crop_file(crops: Path, relative: str) -> Path:
    """Resolve a crop/mask path under AnnotationCrops. Rejects traversal."""
    stripped = unquote(relative).replace("\\", "/").lstrip("/")
    if not stripped or stripped.startswith("/"):
        raise ValueError("invalid path")
    parts = posixpath.normpath(stripped).split("/")
    if parts[0] == ".." or ".." in parts or parts[0] not in FILE_PREFIXES:
        raise ValueError("invalid path")
    target = (crops / Path(*parts)).resolve()
    root = crops.resolve()
    try:
        target.relative_to(root)
    except ValueError as exc:
        raise ValueError("invalid path") from exc
    return target


def encode_session(principal: Principal, secret: bytes) -> str:
    payload = json.dumps(
        {
            "sub": principal.subject,
            "name": principal.display_name,
            "grants": principal.grants,
        },
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    signature = hmac.new(secret, payload, "sha256").hexdigest()
    return payload.hex() + "." + signature


def decode_session(token: str | None, secret: bytes) -> Principal | None:
    if not token or "." not in token:
        return None
    payload_hex, signature = token.rsplit(".", 1)
    try:
        payload = bytes.fromhex(payload_hex)
    except ValueError:
        return None
    expected = hmac.new(secret, payload, "sha256").hexdigest()
    if not hmac.compare_digest(expected, signature):
        return None
    try:
        data = json.loads(payload.decode("utf-8"))
    except json.JSONDecodeError:
        return None
    grants = data.get("grants") or {}
    if not isinstance(grants, dict):
        return None
    cleaned = {
        str(name): str(role)
        for name, role in grants.items()
        if role in {PERMISSION_READ, PERMISSION_REVIEW}
    }
    return Principal(
        subject=str(data.get("sub") or "user"),
        display_name=str(data.get("name") or "user"),
        grants=cleaned,
    )


def content_type_for(path: Path) -> str:
    suffix = path.suffix.lower()
    if suffix in {".jpg", ".jpeg"}:
        return "image/jpeg"
    if suffix == ".png":
        return "image/png"
    if suffix == ".js":
        return "text/javascript; charset=utf-8"
    if suffix == ".css":
        return "text/css; charset=utf-8"
    if suffix == ".html":
        return "text/html; charset=utf-8"
    if suffix == ".json":
        return "application/json; charset=utf-8"
    return "application/octet-stream"


class GalleryHandler(BaseHTTPRequestHandler):
    """HTTP API + static SPA. Does not spawn nornir-build."""

    server_version = "AnnotationGallery/1.0"

    def log_message(self, format: str, *args: Any) -> None:
        sys.stderr.write("%s - %s\n" % (self.address_string(), format % args))

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        path = unquote(parsed.path)
        query = parse_qs(parsed.query)
        if path == "/health":
            self._send_json({"ok": True})
            return
        if path in {"/", "/index.html"}:
            self._send_file(STATIC_DIR / "index.html", "text/html; charset=utf-8")
            return
        if path.startswith("/static/"):
            relative = path[len("/static/") :]
            self._send_static(relative)
            return
        if path == "/api/config":
            self._send_json(
                {
                    "identityMode": identity_mode(),
                    "vikingUrl": viking_template(),
                }
            )
            return
        if path == "/login":
            self._handle_login()
            return
        if path == "/callback":
            self._handle_callback(query)
            return
        if path == "/logout":
            self._clear_session()
            return
        if path == "/api/me":
            principal = self._principal()
            self._send_json(
                {
                    "subject": principal.subject,
                    "displayName": principal.display_name,
                    "volumes": [
                        {"name": name, "permission": role}
                        for name, role in sorted(principal.grants.items())
                    ],
                }
            )
            return
        match = re.fullmatch(r"/api/volumes/([^/]+)/catalog", path)
        if match:
            self._handle_catalog(match.group(1))
            return
        match = re.fullmatch(r"/api/volumes/([^/]+)/file", path)
        if match:
            rel = (query.get("path") or [""])[0]
            self._handle_file(match.group(1), rel)
            return
        self._send_json({"error": "not found"}, status=404)

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        path = unquote(parsed.path)
        match = re.fullmatch(r"/api/volumes/([^/]+)/(ignore|restore)", path)
        if not match:
            self._send_json({"error": "not found"}, status=404)
            return
        volume = match.group(1)
        action = match.group(2)
        principal = self._principal()
        role = principal.grants.get(volume)
        if role is None:
            self._send_json({"error": "not found"}, status=404)
            return
        if role != PERMISSION_REVIEW:
            self._send_json({"error": "review required"}, status=403)
            return
        try:
            body = self._read_json()
            location_id = int(body.get("location_id"))
        except (TypeError, ValueError, json.JSONDecodeError):
            self._send_json({"error": "location_id required"}, status=400)
            return
        try:
            crops = crops_dir(registry_dir(), volume)
        except (ValueError, FileNotFoundError):
            self._send_json({"error": "not found"}, status=404)
            return
        if action == "ignore":
            ignore_location(crops, location_id)
        else:
            restore_location(crops, location_id)
        self._send_json({"ok": True, "location_id": location_id, "ignored": action == "ignore"})

    def _handle_login(self) -> None:
        if identity_mode() != "oidc":
            self._redirect("/")
            return
        oidc = OidcIdentity(env_map())
        state = secrets.token_urlsafe(16)
        redirect_uri = os.environ.get("GALLERY_OIDC_REDIRECT_URI") or self._callback_uri()
        url = oidc.login_url(redirect_uri, state)
        self.send_response(302)
        self.send_header("Location", url)
        self.send_header("Set-Cookie", f"gallery_oidc_state={state}; Path=/; HttpOnly; SameSite=Lax")
        self.end_headers()

    def _handle_callback(self, query: dict[str, list[str]]) -> None:
        if identity_mode() != "oidc":
            self._redirect("/")
            return
        code = (query.get("code") or [""])[0]
        if not code:
            self._send_json({"error": "missing code"}, status=400)
            return
        oidc = OidcIdentity(env_map())
        redirect_uri = os.environ.get("GALLERY_OIDC_REDIRECT_URI") or self._callback_uri()
        try:
            principal = oidc.complete_login(code, redirect_uri, list_registry_names(registry_dir()))
        except PermissionError as exc:
            self._send_json({"error": str(exc)}, status=401)
            return
        cookie = encode_session(principal, session_secret())
        self.send_response(302)
        self.send_header("Location", "/")
        self.send_header(
            "Set-Cookie",
            f"{SESSION_COOKIE}={cookie}; Path=/; HttpOnly; SameSite=Lax",
        )
        self.end_headers()

    def _handle_catalog(self, volume: str) -> None:
        principal = self._principal()
        if volume not in principal.grants:
            self._send_json({"error": "not found"}, status=404)
            return
        try:
            crops = crops_dir(registry_dir(), volume)
        except (ValueError, FileNotFoundError):
            self._send_json({"error": "not found"}, status=404)
            return
        rows = list_catalog_rows(crops)
        self._send_json({"volume": volume, "permission": principal.grants[volume], "rows": rows})

    def _handle_file(self, volume: str, relative: str) -> None:
        principal = self._principal()
        if volume not in principal.grants:
            self._send_json({"error": "not found"}, status=404)
            return
        try:
            crops = crops_dir(registry_dir(), volume)
            target = safe_crop_file(crops, relative)
        except (ValueError, FileNotFoundError):
            self._send_json({"error": "invalid path"}, status=400)
            return
        except OSError:
            self._send_json({"error": "invalid path"}, status=400)
            return
        if not target.is_file():
            self._send_json({"error": "not found"}, status=404)
            return
        self._send_file(target, content_type_for(target))

    def _principal(self) -> Principal:
        names = list_registry_names(registry_dir())
        mode = identity_mode()
        header = self.headers.get("Authorization") or ""
        if header.lower().startswith("bearer "):
            token = header[7:].strip()
            if mode == "stub":
                stub = StubIdentity(env_map())
                principal = stub.principal_from_bearer(token, names)
                if principal is not None:
                    return principal
        cookie = self._cookie(SESSION_COOKIE)
        principal = decode_session(cookie, session_secret())
        if principal is not None:
            grants = intersect_keep(principal.grants, names)
            return Principal(principal.subject, principal.display_name, grants)
        if mode == "stub":
            return StubIdentity(env_map()).principal_for_registry(names)
        return Principal(subject="anonymous", display_name="anonymous", grants={})

    def _cookie(self, name: str) -> str | None:
        header = self.headers.get("Cookie") or ""
        for part in header.split(";"):
            piece = part.strip()
            if piece.startswith(name + "="):
                return piece[len(name) + 1 :]
        return None

    def _callback_uri(self) -> str:
        host = self.headers.get("Host") or "127.0.0.1:8090"
        return f"http://{host}/callback"

    def _read_json(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length") or "0")
        raw = self.rfile.read(length) if length else b"{}"
        payload = json.loads(raw.decode("utf-8") or "{}")
        if not isinstance(payload, dict):
            raise json.JSONDecodeError("object required", "", 0)
        return payload

    def _send_json(self, payload: dict[str, Any], status: int = 200) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _send_file(self, path: Path, content_type: str) -> None:
        if not path.is_file():
            self._send_json({"error": "not found"}, status=404)
            return
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _send_static(self, relative: str) -> None:
        parts = posixpath.normpath(relative).split("/")
        if ".." in parts:
            self._send_json({"error": "invalid path"}, status=400)
            return
        path = (STATIC_DIR / Path(*parts)).resolve()
        try:
            path.relative_to(STATIC_DIR.resolve())
        except ValueError:
            self._send_json({"error": "invalid path"}, status=400)
            return
        self._send_file(path, content_type_for(path))

    def _redirect(self, location: str) -> None:
        self.send_response(302)
        self.send_header("Location", location)
        self.end_headers()

    def _clear_session(self) -> None:
        self.send_response(302)
        self.send_header("Location", "/")
        self.send_header("Set-Cookie", f"{SESSION_COOKIE}=; Path=/; Max-Age=0")
        self.end_headers()


def intersect_keep(grants: dict[str, str], names: list[str]) -> dict[str, str]:
    allowed = set(names)
    return {name: role for name, role in grants.items() if name in allowed}


def make_server(
    host: str = "0.0.0.0",
    port: int = 8090,
) -> ThreadingHTTPServer:
    """Bind the gallery HTTP server."""
    return ThreadingHTTPServer((host, port), GalleryHandler)


def main() -> None:
    host = os.environ.get("GALLERY_HOST") or "0.0.0.0"
    port = int(os.environ.get("GALLERY_PORT") or "8090")
    server = make_server(host, port)
    print(f"annotation-gallery listening on {host}:{port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
