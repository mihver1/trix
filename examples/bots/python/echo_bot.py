from __future__ import annotations

import os
import sys

from trixbot_client import BotClient, RpcError


def required_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise RuntimeError(f"missing required environment variable {name}")
    return value


def env_flag(name: str) -> bool:
    value = os.environ.get(name, "")
    return value.lower() in {"1", "true", "yes"}


def download_target(state_dir: str, message_id: str, file_name: str | None) -> str:
    safe_name = os.path.basename(file_name or "attachment.bin")
    downloads_dir = os.path.join(state_dir, "downloads")
    os.makedirs(downloads_dir, exist_ok=True)
    return os.path.join(downloads_dir, f"{message_id}-{safe_name}")


def main() -> int:
    client = BotClient.from_command_string(os.environ.get("TRIX_BOTD_CMD"))
    try:
        state_dir = required_env("TRIX_BOT_STATE_DIR")
        identity = client.init(
            server_url=required_env("TRIX_SERVER_URL"),
            state_dir=state_dir,
            profile_name=os.environ.get("TRIX_BOT_PROFILE_NAME", "Python Echo Bot"),
            handle=os.environ.get("TRIX_BOT_HANDLE"),
            master_secret_env=os.environ.get("TRIX_BOT_MASTER_SECRET_ENV"),
            plaintext_dev_store=env_flag("TRIX_BOT_PLAINTEXT_STORE"),
        )
        self_account_id = identity["account_id"]
        client.start()

        while True:
            notification = client.next_notification()
            method = notification.get("method")
            params = notification.get("params", {})

            if method == "bot.v1.text_message":
                if params.get("sender_account_id") == self_account_id:
                    continue
                chat_id = params["chat_id"]
                text = params["text"]
                client.send_text(chat_id, f"echo: {text}")
            elif method == "bot.v1.file_message":
                if params.get("sender_account_id") == self_account_id:
                    continue
                chat_id = params["chat_id"]
                message_id = params["message_id"]
                file_name = params.get("file_name")
                output_path = download_target(state_dir, message_id, file_name)
                client.download_file(chat_id, message_id, output_path)
                client.send_text(chat_id, f"saved file: {os.path.basename(output_path)}")
            elif method == "bot.v1.error":
                print(f"bot error: {params.get('message')}", file=sys.stderr)
            elif method == "bot.v1.connection_changed":
                print(
                    f"connection_changed connected={params.get('connected')} mode={params.get('mode')}",
                    file=sys.stderr,
                )
    except KeyboardInterrupt:
        return 0
    except RpcError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    finally:
        try:
            client.stop()
        except Exception:
            pass
        client.close()


if __name__ == "__main__":
    raise SystemExit(main())
