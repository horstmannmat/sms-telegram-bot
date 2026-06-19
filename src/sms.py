# -*- coding: utf-8 -*-
from __future__ import absolute_import, annotations, print_function

import argparse
import asyncio
import logging
import pathlib
import re
import sys
from typing import Optional

from models import Configuration, SMSBot

logger = logging.getLogger(__name__)

DEFAULT_LOG_LEVEL = logging.INFO
_SPURIOUS_SMS = re.compile(r"^\$V\d+$", re.IGNORECASE)


def setup_logging(log_file: Optional[str] = None) -> None:
    if not log_file:
        logging.basicConfig(level=DEFAULT_LOG_LEVEL)
        return

    log_path = pathlib.Path(log_file)
    log_path.parent.mkdir(parents=True, exist_ok=True)

    log_format = "%(asctime)s %(levelname)s %(name)s: %(message)s"
    formatter = logging.Formatter(log_format)
    root = logging.getLogger()
    root.handlers.clear()
    root.setLevel(DEFAULT_LOG_LEVEL)

    # Append: gammu-smsd invokes sms.py once per SMS (no log rotation).
    file_handler = logging.FileHandler(log_path, mode="a", encoding="utf-8")
    file_handler.setFormatter(formatter)
    root.addHandler(file_handler)

    error_log_path = (
        log_path.parent / f"{log_path.stem}-error{log_path.suffix}"
    )
    error_handler = logging.FileHandler(
        error_log_path, mode="a", encoding="utf-8"
    )
    error_handler.setLevel(logging.ERROR)
    error_handler.setFormatter(formatter)
    root.addHandler(error_handler)

    stream_handler = logging.StreamHandler(sys.stderr)
    stream_handler.setFormatter(formatter)
    root.addHandler(stream_handler)

    logger.debug("Logging to %s and %s", log_path, error_log_path)


def _decode_gammu_backup_hex(hex_str: str) -> str:
    hex_str = hex_str.replace(" ", "")
    if not hex_str:
        return ""
    return bytes.fromhex(hex_str).decode("utf-16-be", errors="replace")


def _parse_smsbackup_content(content: str) -> tuple[str, str]:
    sender = "unknown"
    text_fields: list[tuple[int, str]] = []

    for line in content.splitlines():
        if line.startswith("Number = "):
            sender = line.split("=", 1)[1].strip().strip('"')
        elif re.match(r"^Text\d+ = ", line):
            key, value = line.split(" = ", 1)
            text_fields.append((int(key[4:]), value.strip()))
        elif line.startswith("#") and len(line) > 1:
            comment = line[1:].strip()
            if comment:
                return sender, comment

    if text_fields:
        text_fields.sort(key=lambda item: item[0])
        text = "".join(
            _decode_gammu_backup_hex(value) for _, value in text_fields
        )
        return sender, text.strip()

    return sender, ""


def _is_spurious_fragment(text: str) -> bool:
    stripped = text.strip()
    if not stripped:
        return True
    return bool(_SPURIOUS_SMS.match(stripped))


def _sender_from_filename(path: pathlib.Path) -> Optional[str]:
    # Gammu: IN<date>_<time>_<part>_<number>_<status>.txt
    if not path.name.startswith("IN") or path.suffix != ".txt":
        return None
    parts = path.stem.split("_")
    if len(parts) < 4:
        return None
    return parts[3] or None


def _read_one_sms_file(txt_file: pathlib.Path) -> tuple[str, str]:
    logger.debug("Reading SMS from %s", txt_file)
    with open(txt_file, "r", encoding="utf-8") as f:
        content = f.read()

    if "[SMSBackup" in content:
        sender, text = _parse_smsbackup_content(content)
        logger.debug("SMS from %s: %s", sender, text)
        return sender or "unknown", text

    sender = _sender_from_filename(txt_file)
    text = content.strip()

    for line in content.splitlines():
        if line.lower().startswith("from:"):
            sender = line.split(":", 1)[1].strip() or sender
            break

    if content.lstrip().lower().startswith("from:"):
        parts = content.split("\n\n", 1)
        if len(parts) == 2:
            text = parts[1].strip()

    logger.debug("SMS from %s: %s", sender, text)
    return sender or "unknown", text


def _resolve_gammu_sms_path(
    inbox: pathlib.Path, gammu_sms_file: str
) -> Optional[pathlib.Path]:
    raw = pathlib.Path(gammu_sms_file.strip())
    if raw.is_file():
        return raw
    under_inbox = inbox / raw.name
    if under_inbox.is_file():
        return under_inbox
    logger.error(
        "SMS file from gammu not found: %s (also checked %s)",
        raw,
        under_inbox,
    )
    return None


def collect_sms_paths(
    inbox_folder: str, gammu_sms_file: Optional[str]
) -> list[pathlib.Path]:
    inbox = pathlib.Path(inbox_folder.strip())
    if gammu_sms_file:
        path = _resolve_gammu_sms_path(inbox, gammu_sms_file)
        return [path] if path else []
    paths = sorted(inbox.glob("*.txt"))
    if not paths:
        logger.debug("No SMS files in %s", inbox)
    return paths


async def main() -> None:
    parser = argparse.ArgumentParser(
        description="Forward Gammu received SMS files to a Telegram chat.",
    )
    default_config = (
        pathlib.Path(__file__).resolve().parent.parent / "config.pkl"
    )
    parser.add_argument(
        "--log",
        metavar="PATH",
        default=None,
        help="Also write logs to this file (default: stderr only).",
    )
    parser.add_argument(
        "config",
        nargs="?",
        default=str(default_config),
        help="Path to config.pkl (default: %(default)s)",
    )
    parser.add_argument(
        "gammu_sms_file",
        nargs="?",
        help="Path to the new SMS file (appended by gammu-smsd runonreceive).",
    )
    args = parser.parse_args()
    setup_logging(args.log)

    config_file = args.config
    if not pathlib.Path(config_file).exists():
        logger.error("Configuration file not found: %s", config_file)
        sys.exit(1)

    config = Configuration(config_file)
    sms_paths = collect_sms_paths(config.inbox_folder, args.gammu_sms_file)

    if not sms_paths:
        return

    bot = SMSBot(config.token)
    for txt_file in sms_paths:
        try:
            sender, sms_text = _read_one_sms_file(txt_file)
            if _is_spurious_fragment(sms_text):
                logger.info(
                    "Skipping spurious multipart fragment from %s: %s",
                    sender,
                    sms_text,
                )
            else:
                logger.info(
                    "Received Message from %s with Text: %s", sender, sms_text
                )
                await bot.send_message(config.chat_id, sms_text)
        except Exception:
            logger.exception("Failed to forward SMS from %s", txt_file)
            raise
        logger.debug("Deleting %s", txt_file)
        txt_file.unlink()


def main_cli() -> None:
    asyncio.run(main())


if __name__ == "__main__":
    main_cli()
