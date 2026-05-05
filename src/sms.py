# -*- coding: utf-8 -*-
from __future__ import absolute_import, annotations, print_function

import argparse
import asyncio
import logging
import pathlib
import sys
from typing import Optional

from models import Configuration, SMSBot

logger = logging.getLogger(__name__)


def _read_one_sms_file(txt_file: pathlib.Path) -> str:
    logger.debug("Reading SMS from %s", txt_file)
    with open(txt_file, "r", encoding="utf-8") as f:
        content = f.read()
    logger.debug("SMS: %s", content)
    return content


def collect_sms_paths(
    inbox_folder: str, gammu_sms_file: Optional[str]
) -> list[pathlib.Path]:
    inbox = pathlib.Path(inbox_folder)
    if gammu_sms_file:
        path = pathlib.Path(gammu_sms_file)
        if not path.is_file():
            logger.error("SMS file from gammu not found: %s", path)
            return []
        return [path]
    paths = sorted(inbox.glob("*.txt"))
    if not paths:
        logger.debug("No SMS files in %s", inbox)
    return paths


async def main() -> None:
    parser = argparse.ArgumentParser(
        description="Forward Gammu received SMS files to a Telegram chat.",
    )
    default_config = pathlib.Path(__file__).resolve().parent / "config.pkl"
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
            sms_text = _read_one_sms_file(txt_file)
            await bot.send_message(config.chat_id, sms_text)
        except Exception:
            logger.exception("Failed to forward SMS from %s", txt_file)
            raise
        logger.debug("Deleting %s", txt_file)
        pathlib.Path.unlink(txt_file)


def main_cli() -> None:
    logging.basicConfig(level=logging.DEBUG)
    asyncio.run(main())


if __name__ == "__main__":
    main_cli()
