from __future__ import annotations

import json
import queue
import shlex
import subprocess
import threading
from dataclasses import dataclass
from typing import Any


@dataclass
class RpcError(Exception):
    code: int
    message: str

    def __str__(self) -> str:
        return f"json-rpc error {self.code}: {self.message}"


class BotClient:
    def __init__(self, command: list[str] | None = None) -> None:
        self._command = command or ["cargo", "run", "-q", "-p", "trix-botd", "--", "stdio"]
        self._proc = subprocess.Popen(
            self._command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        if self._proc.stdin is None or self._proc.stdout is None:
            raise RuntimeError("failed to start trix-botd stdio process")

        self._stdin = self._proc.stdin
        self._stdout = self._proc.stdout
        self._next_id = 1
        self._responses: dict[int, dict[str, Any]] = {}
        self._notifications: "queue.Queue[dict[str, Any]]" = queue.Queue()
        self._condition = threading.Condition()
        self._closed = False
        self._reader = threading.Thread(target=self._read_loop, daemon=True)
        self._reader.start()

    @classmethod
    def from_command_string(cls, value: str | None) -> "BotClient":
        if value:
            return cls(shlex.split(value))
        return cls()

    def init(
        self,
        *,
        server_url: str,
        state_dir: str,
        profile_name: str,
        handle: str | None = None,
        master_secret_env: str | None = None,
        plaintext_dev_store: bool = False,
    ) -> dict[str, Any]:
        return self.request(
            "bot.v1.init",
            {
                "server_url": server_url,
                "state_dir": state_dir,
                "profile_name": profile_name,
                "handle": handle,
                "master_secret_env": master_secret_env,
                "plaintext_dev_store": plaintext_dev_store,
            },
        )

    def start(self) -> dict[str, Any]:
        return self.request("bot.v1.start", {})

    def stop(self) -> dict[str, Any]:
        return self.request("bot.v1.stop", {})

    def list_chats(self) -> dict[str, Any]:
        return self.request("bot.v1.list_chats", {})

    def get_timeline(self, chat_id: str, limit: int | None = None) -> dict[str, Any]:
        return self.request("bot.v1.get_timeline", {"chat_id": chat_id, "limit": limit})

    def send_text(self, chat_id: str, text: str) -> dict[str, Any]:
        return self.request("bot.v1.send_text", {"chat_id": chat_id, "text": text})

    def send_file(
        self,
        chat_id: str,
        path: str,
        *,
        mime_type: str | None = None,
        file_name: str | None = None,
        width_px: int | None = None,
        height_px: int | None = None,
    ) -> dict[str, Any]:
        return self.request(
            "bot.v1.send_file",
            {
                "chat_id": chat_id,
                "path": path,
                "mime_type": mime_type,
                "file_name": file_name,
                "width_px": width_px,
                "height_px": height_px,
            },
        )

    def download_file(self, chat_id: str, message_id: str, output_path: str) -> dict[str, Any]:
        return self.request(
            "bot.v1.download_file",
            {
                "chat_id": chat_id,
                "message_id": message_id,
                "output_path": output_path,
            },
        )

    def publish_key_packages(self, count: int = 128) -> dict[str, Any]:
        return self.request("bot.v1.publish_key_packages", {"count": count})

    def request(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        with self._condition:
            request_id = self._next_id
            self._next_id += 1

        payload = {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": method,
            "params": params,
        }
        self._stdin.write(json.dumps(payload) + "\n")
        self._stdin.flush()

        with self._condition:
            while request_id not in self._responses:
                if self._closed:
                    raise RuntimeError("trix-botd stdio exited before responding")
                self._condition.wait(timeout=0.1)
            response = self._responses.pop(request_id)

        error = response.get("error")
        if error is not None:
            raise RpcError(int(error["code"]), str(error["message"]))
        return response["result"]

    def next_notification(self, timeout: float | None = None) -> dict[str, Any]:
        return self._notifications.get(timeout=timeout)

    def close(self) -> None:
        try:
            if self._proc.poll() is None:
                self._proc.terminate()
                self._proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self._proc.kill()
            self._proc.wait(timeout=5)

    def _read_loop(self) -> None:
        try:
            for line in self._stdout:
                if not line.strip():
                    continue
                try:
                    message = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if "id" in message:
                    request_id = int(message["id"])
                    with self._condition:
                        self._responses[request_id] = message
                        self._condition.notify_all()
                elif "method" in message:
                    self._notifications.put(message)
        finally:
            with self._condition:
                self._closed = True
                self._condition.notify_all()
