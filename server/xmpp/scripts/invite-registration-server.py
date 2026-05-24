#!/usr/bin/env python3
import base64
import hashlib
import hmac
import json
import mimetypes
import os
import re
import secrets
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


HOST = os.environ.get("TRIX_XMPP_OPERATOR_HOST", "trix.selfhost.ru")
CONFERENCE_HOST = os.environ.get("TRIX_XMPP_CONFERENCE_HOST", f"conference.{HOST}")
API_URL = os.environ.get("TRIX_XMPP_API_URL", "http://127.0.0.1:5280/api").rstrip("/")
BIND = os.environ.get("TRIX_INVITE_BIND", "127.0.0.1")
PORT = int(os.environ.get("TRIX_INVITE_PORT", "8091"))
DEFAULT_STORE_PATH = Path(__file__).resolve().parents[1] / ".state" / "invites.json"
STORE_PATH = Path(os.environ.get("TRIX_INVITE_STORE_PATH", str(DEFAULT_STORE_PATH)))
OPERATOR_TOKEN = os.environ.get("TRIX_INVITE_OPERATOR_TOKEN", "")
DEFAULT_TTL_SECONDS = int(os.environ.get("TRIX_INVITE_DEFAULT_TTL_SECONDS", "604800"))
DRY_RUN = os.environ.get("TRIX_INVITE_DRY_RUN", "0") == "1"
ALLOW_NON_LOOPBACK_API = os.environ.get("TRIX_XMPP_OPERATOR_ALLOW_NON_LOOPBACK", "0") == "1"
TELEGRAM_BOT_TOKEN = os.environ.get("TRIX_TELEGRAM_BOT_TOKEN", "")
STICKER_TOKEN_SECRET = os.environ.get("TRIX_STICKER_TOKEN_SECRET", "")
TELEGRAM_API_BASE_URL = os.environ.get("TRIX_TELEGRAM_API_BASE_URL", "https://api.telegram.org").rstrip("/")
TELEGRAM_FILE_BASE_URL = os.environ.get("TRIX_TELEGRAM_FILE_BASE_URL", "https://api.telegram.org/file").rstrip("/")
TELEGRAM_FAKE = os.environ.get("TRIX_TELEGRAM_FAKE", "0") == "1"
STICKER_FILE_TOKEN_TTL_SECONDS = int(os.environ.get("TRIX_STICKER_FILE_TOKEN_TTL_SECONDS", "900"))
LOCALPART_RE = re.compile(r"^[a-z0-9](?:[a-z0-9._-]{0,30}[a-z0-9])?$")
MUC_LOCALPART_RE = re.compile(r"^[a-z0-9](?:[a-z0-9._-]{0,126}[a-z0-9])?$")
MAX_BODY_BYTES = 16 * 1024
MAX_STICKER_BYTES = 8 * 1024 * 1024
TELEGRAM_PACK_NAME_RE = re.compile(r"^[A-Za-z0-9_]{1,128}$")
MAX_INVITE_METADATA_RETENTION_SECONDS = 30 * 24 * 60 * 60
INVITE_METADATA_RETENTION_SECONDS = MAX_INVITE_METADATA_RETENTION_SECONDS
try:
    INVITE_METADATA_RETENTION_SECONDS = int(
        os.environ.get("TRIX_INVITE_METADATA_RETENTION_SECONDS", str(INVITE_METADATA_RETENTION_SECONDS))
    )
except ValueError:
    raise SystemExit("TRIX_INVITE_METADATA_RETENTION_SECONDS must be an integer")
if INVITE_METADATA_RETENTION_SECONDS > MAX_INVITE_METADATA_RETENTION_SECONDS:
    raise SystemExit("TRIX_INVITE_METADATA_RETENTION_SECONDS must be no greater than 2592000")


class InviteError(Exception):
    def __init__(self, status, code, message):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message


class InviteStore:
    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()

    def create_invite(self, localpart, display_name, ttl_seconds, issued_by=None):
        code = secrets.token_urlsafe(24)
        now = now_iso()
        invite = {
            "id": secrets.token_hex(12),
            "code_hash": hash_code(code),
            "localpart": localpart,
            "display_name": normalized_optional_string(display_name),
            "issued_by": issued_by,
            "created_at": now,
            "expires_at": iso_from_epoch(time.time() + ttl_seconds),
            "redeeming_at": None,
            "redeemed_at": None,
            "redeemed_user": None,
        }
        with self.lock:
            store = self._load()
            store.setdefault("invites", []).append(invite)
            self._save(store)
        return {
            "invite_code": code,
            "localpart": localpart,
            "display_name": invite["display_name"],
            "expires_at": invite["expires_at"],
        }

    def begin_redeem(self, invite_code, requested_localpart):
        code_hash = hash_code(invite_code)
        with self.lock:
            store = self._load()
            invite = self._find_invite(store, code_hash)
            if invite is None:
                raise InviteError(HTTPStatus.NOT_FOUND, "invite_not_found", "Invite code is not valid.")
            if invite.get("redeemed_at"):
                raise InviteError(HTTPStatus.CONFLICT, "invite_used", "Invite code has already been used.")
            if invite.get("redeeming_at"):
                raise InviteError(HTTPStatus.CONFLICT, "invite_in_progress", "Invite code is already being redeemed.")
            if is_expired(invite["expires_at"]):
                raise InviteError(HTTPStatus.GONE, "invite_expired", "Invite code has expired.")

            reserved_localpart = invite.get("localpart")
            if reserved_localpart:
                if requested_localpart and requested_localpart != reserved_localpart:
                    raise InviteError(HTTPStatus.CONFLICT, "localpart_reserved", "Invite code is reserved for another handle.")
                localpart = reserved_localpart
            else:
                localpart = requested_localpart

            localpart = normalize_localpart(localpart)
            invite["redeeming_at"] = now_iso()
            invite["redeemed_user"] = f"{localpart}@{HOST}"
            self._save(store)
            return invite["id"], localpart, invite.get("display_name")

    def finish_redeem(self, invite_id, user_id):
        with self.lock:
            store = self._load()
            invite = self._find_invite_by_id(store, invite_id)
            if invite is not None:
                invite["redeeming_at"] = None
                invite["redeemed_at"] = now_iso()
                invite["redeemed_user"] = user_id
                self._save(store)

    def clear_redeem(self, invite_id):
        with self.lock:
            store = self._load()
            invite = self._find_invite_by_id(store, invite_id)
            if invite is not None and not invite.get("redeemed_at"):
                invite["redeeming_at"] = None
                invite["redeemed_user"] = None
                self._save(store)

    def purge_metadata(self, retention_seconds=INVITE_METADATA_RETENTION_SECONDS, now_epoch=None):
        cutoff_epoch = (now_epoch if now_epoch is not None else time.time()) - retention_seconds
        with self.lock:
            store = self._load()
            retained = []
            removed = 0
            for invite in store.get("invites", []):
                if should_purge_invite_metadata(invite, cutoff_epoch):
                    removed += 1
                else:
                    retained.append(invite)
            if removed:
                store["invites"] = retained
                self._save(store)
            return {
                "removed": removed,
                "remaining": len(retained),
            }

    def _load(self):
        if not self.path.exists() or self.path.stat().st_size == 0:
            return {"version": 1, "invites": []}
        with self.path.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
        data.setdefault("version", 1)
        data.setdefault("invites", [])
        return data

    def _save(self, store):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd, temp_path = tempfile.mkstemp(prefix=".invites.", suffix=".json", dir=str(self.path.parent))
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(store, handle, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
                handle.write("\n")
            os.chmod(temp_path, 0o600)
            os.replace(temp_path, self.path)
        finally:
            if os.path.exists(temp_path):
                os.unlink(temp_path)

    @staticmethod
    def _find_invite(store, code_hash):
        for invite in store.get("invites", []):
            if hmac.compare_digest(invite.get("code_hash", ""), code_hash):
                return invite
        return None

    @staticmethod
    def _find_invite_by_id(store, invite_id):
        for invite in store.get("invites", []):
            if invite.get("id") == invite_id:
                return invite
        return None


store = InviteStore(STORE_PATH)


class Handler(BaseHTTPRequestHandler):
    server_version = "TrixInviteRegistration/1.0"

    def do_GET(self):
        if self.path == "/v1/system/health":
            self.write_json(HTTPStatus.OK, {"status": "ok"})
            return
        self.write_json(HTTPStatus.NOT_FOUND, {"error": "not_found", "message": "Unknown endpoint."})

    def do_POST(self):
        try:
            if self.path == "/v1/operator/invites":
                self.require_operator_token()
                self.create_invite()
                return
            if self.path == "/v1/invites":
                issuer = self.require_account_auth()
                self.create_invite(issued_by=issuer)
                return
            if self.path == "/v1/account/password":
                issuer = self.require_account_auth()
                self.change_account_password(issuer)
                return
            if self.path == "/v1/groups/leave":
                issuer = self.require_account_auth()
                self.leave_group(issuer)
                return
            if self.path == "/v1/stickers/telegram/packs":
                self.require_account_auth()
                self.import_telegram_sticker_pack()
                return
            if self.path == "/v1/stickers/telegram/file":
                self.require_account_auth()
                self.download_telegram_sticker_file()
                return
            if self.path == "/v1/registration/redeem":
                self.redeem_invite()
                return
            self.write_json(HTTPStatus.NOT_FOUND, {"error": "not_found", "message": "Unknown endpoint."})
        except InviteError as error:
            self.write_json(error.status, {"error": error.code, "message": error.message})
        except Exception:
            self.write_json(
                HTTPStatus.INTERNAL_SERVER_ERROR,
                {"error": "internal_error", "message": "Invite or account operation failed."},
            )

    def create_invite(self, issued_by=None):
        body = self.read_json_body()
        localpart = normalized_optional_string(body.get("localpart"))
        if localpart is not None:
            localpart = normalize_localpart(localpart)
        display_name = normalized_optional_string(body.get("display_name"))
        try:
            ttl_seconds = int(body.get("ttl_seconds") or DEFAULT_TTL_SECONDS)
        except (TypeError, ValueError):
            raise InviteError(HTTPStatus.BAD_REQUEST, "invalid_ttl", "Invite TTL must be a number.")
        if ttl_seconds < 60 or ttl_seconds > 60 * 60 * 24 * 30:
            raise InviteError(HTTPStatus.BAD_REQUEST, "invalid_ttl", "Invite TTL must be between one minute and thirty days.")

        self.write_json(HTTPStatus.CREATED, store.create_invite(localpart, display_name, ttl_seconds, issued_by=issued_by))

    def change_account_password(self, issuer):
        body = self.read_json_body()
        new_password = normalized_required_string(body.get("new_password"), "new_password")
        if len(new_password) < 12:
            raise InviteError(HTTPStatus.BAD_REQUEST, "weak_password", "Password must be at least 12 characters.")

        localpart = issuer.split("@", 1)[0]
        try:
            change_account_password(localpart, new_password)
        except Exception:
            raise InviteError(HTTPStatus.BAD_GATEWAY, "password_change_failed", "Password change failed.")

        self.write_json(
            HTTPStatus.OK,
            {
                "user_id": issuer,
                "changed_at": now_iso(),
            },
        )

    def leave_group(self, issuer):
        body = self.read_json_body()
        room_localpart, room_host = normalized_muc_room_parts(body.get("room_id"))
        try:
            remove_user_from_muc(room_localpart, issuer)
        except InviteError:
            raise
        except Exception:
            raise InviteError(HTTPStatus.BAD_GATEWAY, "group_leave_failed", "Group leave failed.")

        self.write_json(
            HTTPStatus.OK,
            {
                "room_id": f"{room_localpart}@{room_host}",
                "left": True,
            },
        )

    def import_telegram_sticker_pack(self):
        ensure_sticker_import_config()
        body = self.read_json_body()
        pack_name = normalize_telegram_pack_name(
            body.get("url") or body.get("pack_url") or body.get("name") or body.get("pack_name")
        )
        pack = fetch_telegram_sticker_pack(pack_name)
        self.write_json(HTTPStatus.OK, pack)

    def download_telegram_sticker_file(self):
        ensure_sticker_import_config()
        body = self.read_json_body()
        token = normalized_required_string(body.get("file_token"), "file_token")
        payload = verify_sticker_file_token(token)
        data, mime_type = fetch_telegram_sticker_file(payload)
        filename = safe_sticker_filename(
            payload.get("filename"),
            payload.get("file_unique_id", "sticker"),
            mime_type,
        )
        self.write_binary(
            HTTPStatus.OK,
            data,
            content_type=mime_type,
            extra_headers={
                "Content-Disposition": f'attachment; filename="{filename}"',
                "X-Trix-Sticker-Filename": filename,
            },
        )

    def redeem_invite(self):
        body = self.read_json_body()
        invite_code = normalize_invite_code(body.get("invite_code"))
        localpart = normalized_optional_string(body.get("localpart"))
        password = normalized_required_string(body.get("password"), "password")
        display_name = normalized_optional_string(body.get("display_name"))
        if len(password) < 12:
            raise InviteError(HTTPStatus.BAD_REQUEST, "weak_password", "Password must be at least 12 characters.")

        invite_id, final_localpart, reserved_display_name = store.begin_redeem(invite_code, localpart)
        user_id = f"{final_localpart}@{HOST}"
        try:
            provision_user(final_localpart, password)
        except Exception:
            store.clear_redeem(invite_id)
            raise InviteError(HTTPStatus.BAD_GATEWAY, "provision_failed", "Account provisioning failed.")

        store.finish_redeem(invite_id, user_id)
        self.write_json(
            HTTPStatus.CREATED,
            {
                "user_id": user_id,
                "display_name": display_name or reserved_display_name,
            },
        )

    def read_json_body(self):
        try:
            content_length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            raise InviteError(HTTPStatus.BAD_REQUEST, "invalid_request", "Invalid content length.")
        if content_length <= 0 or content_length > MAX_BODY_BYTES:
            raise InviteError(HTTPStatus.BAD_REQUEST, "invalid_request", "Invalid request body.")
        try:
            return json.loads(self.rfile.read(content_length).decode("utf-8"))
        except json.JSONDecodeError:
            raise InviteError(HTTPStatus.BAD_REQUEST, "invalid_json", "Request body must be JSON.")

    def require_operator_token(self):
        expected = OPERATOR_TOKEN.strip()
        header = self.headers.get("Authorization", "")
        prefix = "Bearer "
        provided = header[len(prefix):].strip() if header.startswith(prefix) else ""
        if not expected or not hmac.compare_digest(provided, expected):
            raise InviteError(HTTPStatus.UNAUTHORIZED, "unauthorized", "Operator token is required.")

    def require_account_auth(self):
        header = self.headers.get("Authorization", "")
        prefix = "Basic "
        if not header.startswith(prefix):
            raise InviteError(HTTPStatus.UNAUTHORIZED, "unauthorized", "Account credentials are required.")

        try:
            decoded = base64.b64decode(header[len(prefix):].strip(), validate=True).decode("utf-8")
        except Exception:
            raise InviteError(HTTPStatus.UNAUTHORIZED, "unauthorized", "Account credentials are invalid.")

        if ":" not in decoded:
            raise InviteError(HTTPStatus.UNAUTHORIZED, "unauthorized", "Account credentials are invalid.")

        user_id, password = decoded.split(":", 1)
        localpart, host = normalized_jid_parts(user_id)
        if host != HOST or not password:
            raise InviteError(HTTPStatus.UNAUTHORIZED, "unauthorized", "Account credentials are invalid.")
        if not check_account_password(localpart, password):
            raise InviteError(HTTPStatus.UNAUTHORIZED, "unauthorized", "Account credentials are invalid.")

        return f"{localpart}@{HOST}"

    def write_json(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(int(status))
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def write_binary(self, status, data, content_type="application/octet-stream", extra_headers=None):
        self.send_response(int(status))
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        for key, value in (extra_headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.log_date_time_string(), fmt % args))


def provision_user(localpart, password):
    if DRY_RUN:
        return
    api_post(
        "register",
        {
            "user": localpart,
            "host": HOST,
            "password": password,
        },
    )


def check_account_password(localpart, password):
    if DRY_RUN:
        return True
    try:
        response = api_post(
            "check_password",
            {
                "user": localpart,
                "host": HOST,
                "password": password,
            },
        )
    except Exception:
        return False

    normalized = response.strip()
    if not normalized or normalized == '""':
        return True
    try:
        parsed = json.loads(normalized)
    except json.JSONDecodeError:
        return False
    return parsed == 0 or parsed == ""


def change_account_password(localpart, new_password):
    if DRY_RUN:
        return
    api_post(
        "change_password",
        {
            "user": localpart,
            "host": HOST,
            "newpass": new_password,
        },
    )


def remove_user_from_muc(room_localpart, user_jid):
    affiliation = muc_affiliation(room_localpart, user_jid)
    if affiliation == "owner":
        raise InviteError(
            HTTPStatus.CONFLICT,
            "owner_leave_requires_transfer",
            "Room owners must transfer ownership before leaving.",
        )
    if affiliation not in {"admin", "member"}:
        raise InviteError(HTTPStatus.FORBIDDEN, "not_group_member", "Account is not a member of this group.")

    user, host = normalized_jid_parts(user_jid)
    if DRY_RUN:
        return
    response = api_post(
        "set_room_affiliation",
        {
            "room": room_localpart,
            "service": CONFERENCE_HOST,
            "user": user,
            "host": host,
            "affiliation": "none",
        },
    )
    if not api_success_response(response):
        raise RuntimeError("ejabberd set_room_affiliation returned failure")


def muc_affiliation(room_localpart, user_jid):
    if DRY_RUN:
        return "admin"
    response = api_post(
        "get_room_affiliation",
        {
            "room": room_localpart,
            "service": CONFERENCE_HOST,
            "jid": user_jid,
        },
    )
    parsed = parsed_api_response(response)
    if isinstance(parsed, dict):
        affiliation = parsed.get("affiliation")
    else:
        affiliation = parsed
    return str(affiliation or "none").strip().lower()


def api_success_response(response):
    parsed = parsed_api_response(response)
    return parsed in (None, "", 0)


def parsed_api_response(response):
    normalized = (response or "").strip()
    if not normalized or normalized == '""':
        return None
    try:
        return json.loads(normalized)
    except json.JSONDecodeError:
        return normalized.strip('"')


def api_post(command, payload):
    url = f"{API_URL}/{command}"
    data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            return response.read().decode("utf-8")
    except urllib.error.HTTPError as error:
        error.read()
        raise RuntimeError(f"ejabberd API returned HTTP {error.code}") from error
    except urllib.error.URLError as error:
        raise RuntimeError("ejabberd API is unreachable") from error


def ensure_sticker_import_config():
    if not TELEGRAM_BOT_TOKEN.strip():
        raise InviteError(HTTPStatus.SERVICE_UNAVAILABLE, "telegram_import_unavailable", "Telegram sticker import is not configured.")
    if not STICKER_TOKEN_SECRET.strip():
        raise InviteError(HTTPStatus.SERVICE_UNAVAILABLE, "telegram_import_unavailable", "Telegram sticker import is not configured.")


def normalize_telegram_pack_name(value):
    raw = normalized_required_string(value, "pack_name")
    parsed = urllib.parse.urlparse(raw)
    if parsed.scheme and parsed.netloc:
        host = parsed.netloc.lower()
        path_parts = [part for part in parsed.path.split("/") if part]
        if host in {"t.me", "telegram.me"} and len(path_parts) >= 2 and path_parts[0].lower() == "addstickers":
            raw = path_parts[1]
        else:
            raise InviteError(HTTPStatus.BAD_REQUEST, "invalid_sticker_pack", "Telegram sticker pack link is invalid.")
    else:
        raw = raw.strip().rstrip("/")
        lowered = raw.lower()
        if lowered.startswith("t.me/addstickers/") or lowered.startswith("telegram.me/addstickers/"):
            raw = raw.rstrip("/").rsplit("/", 1)[-1]

    pack_name = urllib.parse.unquote(raw.strip().split("?", 1)[0].split("#", 1)[0]).strip()
    if not TELEGRAM_PACK_NAME_RE.fullmatch(pack_name):
        raise InviteError(HTTPStatus.BAD_REQUEST, "invalid_sticker_pack", "Telegram sticker pack name is invalid.")
    return pack_name


def fetch_telegram_sticker_pack(pack_name):
    response = telegram_api_json("getStickerSet", {"name": pack_name})
    result = response.get("result") or {}
    title = normalized_optional_string(result.get("title")) or pack_name
    returned_name = normalized_optional_string(result.get("name")) or pack_name
    pack_id = telegram_pack_id(returned_name)
    stickers = []
    unsupported_count = 0

    for sticker in result.get("stickers") or []:
        if not is_supported_static_telegram_sticker(sticker):
            unsupported_count += 1
            continue
        sticker_payload = telegram_sticker_payload(sticker, returned_name, title, pack_id)
        if sticker_payload is None:
            unsupported_count += 1
            continue
        stickers.append(sticker_payload)

    return {
        "pack": {
            "id": pack_id,
            "title": title,
            "source": {
                "kind": "telegram",
                "name": returned_name,
                "url": f"https://t.me/addstickers/{returned_name}",
            },
            "stickers": stickers,
        },
        "unsupported_count": unsupported_count,
    }


def telegram_sticker_payload(sticker, pack_name, pack_title, pack_id):
    file_id = normalized_optional_string(sticker.get("file_id"))
    file_unique_id = normalized_optional_string(sticker.get("file_unique_id"))
    if file_id is None or file_unique_id is None:
        return None

    mime_type = "image/webp"
    filename = safe_sticker_filename(None, file_unique_id, mime_type)
    width = integer_value(sticker.get("width"))
    height = integer_value(sticker.get("height"))
    file_size = integer_value(sticker.get("file_size"))
    token = sign_sticker_file_token(
        {
            "file_id": file_id,
            "file_unique_id": file_unique_id,
            "pack_name": pack_name,
            "pack_title": pack_title,
            "filename": filename,
            "mime_type": mime_type,
            "exp": int(time.time()) + STICKER_FILE_TOKEN_TTL_SECONDS,
        }
    )
    return {
        "id": f"telegram:{file_unique_id.lower()}",
        "pack_id": pack_id,
        "emoji": normalized_optional_string(sticker.get("emoji")),
        "filename": filename,
        "mime_type": mime_type,
        "width": width,
        "height": height,
        "size_bytes": file_size,
        "file_token": token,
        "source": {
            "kind": "telegram",
            "name": pack_name,
            "url": f"https://t.me/addstickers/{pack_name}",
        },
    }


def fetch_telegram_sticker_file(token_payload):
    file_id = normalized_optional_string(token_payload.get("file_id"))
    if file_id is None:
        raise InviteError(HTTPStatus.BAD_REQUEST, "invalid_file_token", "Sticker file token is invalid.")

    file_info = telegram_api_json("getFile", {"file_id": file_id}).get("result") or {}
    file_path = normalized_optional_string(file_info.get("file_path"))
    file_size = integer_value(file_info.get("file_size"))
    if file_path is None:
        raise InviteError(HTTPStatus.BAD_GATEWAY, "telegram_file_unavailable", "Telegram sticker file is unavailable.")
    if file_size is not None and file_size > MAX_STICKER_BYTES:
        raise InviteError(HTTPStatus.BAD_GATEWAY, "telegram_file_too_large", "Telegram sticker file is too large.")

    data = telegram_file_bytes(file_path)
    if len(data) > MAX_STICKER_BYTES:
        raise InviteError(HTTPStatus.BAD_GATEWAY, "telegram_file_too_large", "Telegram sticker file is too large.")
    mime_type = mimetypes.guess_type(file_path)[0] or normalized_optional_string(token_payload.get("mime_type")) or "application/octet-stream"
    if not mime_type.startswith("image/"):
        raise InviteError(HTTPStatus.BAD_GATEWAY, "telegram_file_unsupported", "Telegram sticker file format is not supported.")
    return data, mime_type


def telegram_api_json(method, payload):
    if TELEGRAM_FAKE:
        return fake_telegram_api_json(method, payload)

    url = f"{TELEGRAM_API_BASE_URL}/bot{TELEGRAM_BOT_TOKEN}/{method}"
    data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            parsed = json.loads(response.read().decode("utf-8"))
    except (urllib.error.HTTPError, urllib.error.URLError, json.JSONDecodeError):
        raise InviteError(HTTPStatus.BAD_GATEWAY, "telegram_unavailable", "Telegram sticker import failed.")

    if not parsed.get("ok"):
        raise InviteError(HTTPStatus.BAD_GATEWAY, "telegram_unavailable", "Telegram sticker import failed.")
    return parsed


def telegram_file_bytes(file_path):
    if TELEGRAM_FAKE:
        return fake_telegram_file_bytes(file_path)

    quoted_path = urllib.parse.quote(file_path, safe="/")
    request = urllib.request.Request(f"{TELEGRAM_FILE_BASE_URL}/bot{TELEGRAM_BOT_TOKEN}/{quoted_path}", method="GET")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            data = response.read(MAX_STICKER_BYTES + 1)
    except (urllib.error.HTTPError, urllib.error.URLError):
        raise InviteError(HTTPStatus.BAD_GATEWAY, "telegram_file_unavailable", "Telegram sticker file is unavailable.")
    return data


def fake_telegram_api_json(method, payload):
    if method == "getStickerSet":
        name = normalized_optional_string(payload.get("name")) or "FakePack"
        return {
            "ok": True,
            "result": {
                "name": name,
                "title": "Fake Telegram Pack",
                "sticker_type": "regular",
                "stickers": [
                    {
                        "file_id": "fake-static-file-id",
                        "file_unique_id": "fake-static-unique",
                        "type": "regular",
                        "width": 512,
                        "height": 512,
                        "is_animated": False,
                        "is_video": False,
                        "emoji": "🙂",
                        "file_size": 68,
                    },
                    {
                        "file_id": "fake-animated-file-id",
                        "file_unique_id": "fake-animated-unique",
                        "type": "regular",
                        "width": 512,
                        "height": 512,
                        "is_animated": True,
                        "is_video": False,
                        "emoji": "✨",
                    },
                    {
                        "file_id": "fake-video-file-id",
                        "file_unique_id": "fake-video-unique",
                        "type": "regular",
                        "width": 512,
                        "height": 512,
                        "is_animated": False,
                        "is_video": True,
                        "emoji": "🎬",
                    },
                ],
            },
        }
    if method == "getFile":
        file_id = normalized_optional_string(payload.get("file_id"))
        if file_id != "fake-static-file-id":
            return {"ok": False}
        return {
            "ok": True,
            "result": {
                "file_id": file_id,
                "file_unique_id": "fake-static-unique",
                "file_size": 68,
                "file_path": "stickers/fake-static.png",
            },
        }
    return {"ok": False}


def fake_telegram_file_bytes(file_path):
    if file_path != "stickers/fake-static.png":
        raise InviteError(HTTPStatus.BAD_GATEWAY, "telegram_file_unavailable", "Telegram sticker file is unavailable.")
    return base64.b64decode(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/lZG3TQAAAABJRU5ErkJggg=="
    )


def is_supported_static_telegram_sticker(sticker):
    if sticker.get("type") != "regular":
        return False
    if bool(sticker.get("is_animated")) or bool(sticker.get("is_video")):
        return False
    return True


def sign_sticker_file_token(payload):
    body = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    encoded_body = base64.urlsafe_b64encode(body).decode("ascii").rstrip("=")
    signature = hmac.new(STICKER_TOKEN_SECRET.encode("utf-8"), encoded_body.encode("ascii"), hashlib.sha256).digest()
    encoded_signature = base64.urlsafe_b64encode(signature).decode("ascii").rstrip("=")
    return f"{encoded_body}.{encoded_signature}"


def verify_sticker_file_token(token):
    if "." not in token:
        raise InviteError(HTTPStatus.BAD_REQUEST, "invalid_file_token", "Sticker file token is invalid.")
    encoded_body, encoded_signature = token.split(".", 1)
    expected = hmac.new(STICKER_TOKEN_SECRET.encode("utf-8"), encoded_body.encode("ascii"), hashlib.sha256).digest()
    try:
        provided = base64.urlsafe_b64decode(pad_base64(encoded_signature))
    except Exception:
        raise InviteError(HTTPStatus.BAD_REQUEST, "invalid_file_token", "Sticker file token is invalid.")
    if not hmac.compare_digest(provided, expected):
        raise InviteError(HTTPStatus.UNAUTHORIZED, "invalid_file_token", "Sticker file token is invalid.")

    try:
        payload = json.loads(base64.urlsafe_b64decode(pad_base64(encoded_body)).decode("utf-8"))
    except Exception:
        raise InviteError(HTTPStatus.BAD_REQUEST, "invalid_file_token", "Sticker file token is invalid.")

    expires_at = integer_value(payload.get("exp"))
    if expires_at is None or expires_at <= int(time.time()):
        raise InviteError(HTTPStatus.GONE, "file_token_expired", "Sticker file token has expired.")
    return payload


def pad_base64(value):
    return value + ("=" * (-len(value) % 4))


def telegram_pack_id(pack_name):
    return f"telegram:{pack_name.lower()}"


def safe_sticker_filename(value, fallback_id, mime_type):
    raw = normalized_optional_string(value) or fallback_id
    extension = extension_for_mime_type(mime_type)
    safe = re.sub(r"[^A-Za-z0-9._-]+", "-", raw).strip(".-")
    if not safe:
        safe = "sticker"
    if extension and not safe.lower().endswith(f".{extension}"):
        safe = f"{safe}.{extension}"
    return safe[:120]


def extension_for_mime_type(mime_type):
    if mime_type == "image/png":
        return "png"
    if mime_type in {"image/jpeg", "image/jpg"}:
        return "jpg"
    if mime_type == "image/gif":
        return "gif"
    if mime_type == "image/webp":
        return "webp"
    guessed = mimetypes.guess_extension(mime_type or "")
    return guessed.lstrip(".") if guessed else "bin"


def integer_value(value):
    if value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def normalize_invite_code(value):
    code = normalized_required_string(value, "invite_code")
    compact = "".join(code.split())
    if len(compact) < 16 or len(compact) > 256:
        raise InviteError(HTTPStatus.BAD_REQUEST, "invalid_invite", "Invite code is invalid.")
    return compact


def normalize_localpart(value):
    localpart = normalized_required_string(value, "localpart").lower()
    if not LOCALPART_RE.fullmatch(localpart):
        raise InviteError(HTTPStatus.BAD_REQUEST, "invalid_localpart", "Handle must use lowercase letters, numbers, dot, dash, or underscore.")
    return localpart


def normalized_jid_parts(value):
    jid = normalized_required_string(value, "user_id").lower()
    if jid.startswith("@") and ":" in jid:
        localpart, host = jid[1:].split(":", 1)
    elif "@" in jid:
        localpart, host = jid.split("@", 1)
    else:
        raise InviteError(HTTPStatus.UNAUTHORIZED, "unauthorized", "Account credentials are invalid.")
    return normalize_localpart(localpart), host


def normalized_muc_room_parts(value):
    room_id = normalized_required_string(value, "room_id").lower()
    if room_id.count("@") != 1:
        raise InviteError(HTTPStatus.BAD_REQUEST, "invalid_room", "Group room id must be a local MUC JID.")
    localpart, host = room_id.split("@", 1)
    if host != CONFERENCE_HOST or not MUC_LOCALPART_RE.fullmatch(localpart):
        raise InviteError(HTTPStatus.BAD_REQUEST, "invalid_room", "Group room id must be a local MUC JID.")
    return localpart, host


def normalized_required_string(value, field):
    normalized = normalized_optional_string(value)
    if normalized is None:
        raise InviteError(HTTPStatus.BAD_REQUEST, "missing_field", f"{field} is required.")
    return normalized


def normalized_optional_string(value):
    if value is None:
        return None
    if not isinstance(value, str):
        raise InviteError(HTTPStatus.BAD_REQUEST, "invalid_field", "String field expected.")
    trimmed = value.strip()
    return trimmed or None


def hash_code(code):
    return hashlib.sha256(code.encode("utf-8")).hexdigest()


def now_iso():
    return iso_from_epoch(time.time())


def iso_from_epoch(epoch):
    return datetime.fromtimestamp(epoch, tz=timezone.utc).isoformat().replace("+00:00", "Z")


def is_expired(expires_at):
    parsed_epoch = parse_iso_epoch(expires_at)
    return parsed_epoch is not None and parsed_epoch <= time.time()


def should_purge_invite_metadata(invite, cutoff_epoch):
    redeemed_epoch = parse_iso_epoch(invite.get("redeemed_at"))
    if redeemed_epoch is not None:
        return redeemed_epoch <= cutoff_epoch

    expires_epoch = parse_iso_epoch(invite.get("expires_at"))
    return expires_epoch is not None and expires_epoch <= cutoff_epoch


def parse_iso_epoch(value):
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        parsed = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.timestamp()


def ensure_safe_configuration():
    if not OPERATOR_TOKEN.strip():
        raise SystemExit("TRIX_INVITE_OPERATOR_TOKEN is required")
    if not DRY_RUN:
        parsed = urllib.parse.urlparse(API_URL)
        is_loopback = parsed.hostname in {"127.0.0.1", "localhost", "::1"}
        if not is_loopback and not ALLOW_NON_LOOPBACK_API:
            raise SystemExit("refusing non-loopback TRIX_XMPP_API_URL; keep ejabberd mod_http_api private")


def main():
    if len(sys.argv) > 1:
        if sys.argv == [sys.argv[0], "--purge-invite-metadata"]:
            if INVITE_METADATA_RETENTION_SECONDS <= 0:
                raise SystemExit("TRIX_INVITE_METADATA_RETENTION_SECONDS must be greater than 0")
            result = store.purge_metadata(INVITE_METADATA_RETENTION_SECONDS)
            print(
                f"invite_metadata_purge removed={result['removed']} remaining={result['remaining']}",
                flush=True,
            )
            return
        raise SystemExit(
            "usage: invite-registration-server.py [--purge-invite-metadata] (configure "
            "TRIX_INVITE_METADATA_RETENTION_SECONDS to set purge window)"
        )

    ensure_safe_configuration()
    httpd = ThreadingHTTPServer((BIND, PORT), Handler)
    print(f"invite_registration_server=ready bind={BIND} port={PORT} store={STORE_PATH}", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
