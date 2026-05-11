#!/usr/bin/env python3
import base64
import hashlib
import hmac
import json
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
API_URL = os.environ.get("TRIX_XMPP_API_URL", "http://127.0.0.1:5280/api").rstrip("/")
BIND = os.environ.get("TRIX_INVITE_BIND", "127.0.0.1")
PORT = int(os.environ.get("TRIX_INVITE_PORT", "8091"))
DEFAULT_STORE_PATH = Path(__file__).resolve().parents[1] / ".state" / "invites.json"
STORE_PATH = Path(os.environ.get("TRIX_INVITE_STORE_PATH", str(DEFAULT_STORE_PATH)))
OPERATOR_TOKEN = os.environ.get("TRIX_INVITE_OPERATOR_TOKEN", "")
DEFAULT_TTL_SECONDS = int(os.environ.get("TRIX_INVITE_DEFAULT_TTL_SECONDS", "604800"))
DRY_RUN = os.environ.get("TRIX_INVITE_DRY_RUN", "0") == "1"
ALLOW_NON_LOOPBACK_API = os.environ.get("TRIX_XMPP_OPERATOR_ALLOW_NON_LOOPBACK", "0") == "1"
LOCALPART_RE = re.compile(r"^[a-z0-9](?:[a-z0-9._-]{0,30}[a-z0-9])?$")
MAX_BODY_BYTES = 16 * 1024


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
    parsed = datetime.fromisoformat(expires_at.replace("Z", "+00:00"))
    return parsed.timestamp() <= time.time()


def ensure_safe_configuration():
    if not OPERATOR_TOKEN.strip():
        raise SystemExit("TRIX_INVITE_OPERATOR_TOKEN is required")
    if not DRY_RUN:
        parsed = urllib.parse.urlparse(API_URL)
        is_loopback = parsed.hostname in {"127.0.0.1", "localhost", "::1"}
        if not is_loopback and not ALLOW_NON_LOOPBACK_API:
            raise SystemExit("refusing non-loopback TRIX_XMPP_API_URL; keep ejabberd mod_http_api private")


def main():
    ensure_safe_configuration()
    httpd = ThreadingHTTPServer((BIND, PORT), Handler)
    print(f"invite_registration_server=ready bind={BIND} port={PORT} store={STORE_PATH}", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
