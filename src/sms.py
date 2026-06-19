# -*- coding: utf-8 -*-
from __future__ import absolute_import, annotations, print_function

import argparse
import asyncio
import logging
import pathlib
import sys
import time
from typing import Optional

from models import Configuration, SMSBot

logger = logging.getLogger(__name__)

DEFAULT_LOG_LEVEL = logging.INFO


def setup_logging(log_file: Optional[str] = None) -> None:
    if not log_file:
        logging.basicConfig(level=DEFAULT_LOG_LEVEL)
        return

    log_path = pathlib.Path(log_file)
    log_path.parent.mkdir(parents=True, exist_ok=True)

    archived = None
    if log_path.exists():
        archived = (
            log_path.parent / f"{log_path.name}_{int(time.time())}.log.old"
        )
        log_path.rename(archived)

    log_format = "%(asctime)s %(levelname)s %(name)s: %(message)s"
    root = logging.getLogger()
    root.handlers.clear()
    root.setLevel(DEFAULT_LOG_LEVEL)

    file_handler = logging.FileHandler(log_path, encoding="utf-8")
    file_handler.setFormatter(logging.Formatter(log_format))
    root.addHandler(file_handler)

    stream_handler = logging.StreamHandler(sys.stderr)
    stream_handler.setFormatter(logging.Formatter(log_format))
    root.addHandler(stream_handler)

    if archived is not None:
        logger.debug("Previous log moved to %s", archived)
    logger.debug("Logging to %s", log_path)


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
