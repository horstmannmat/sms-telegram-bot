# -*- coding: utf-8 -*-
from __future__ import absolute_import, annotations, print_function

import asyncio
import logging
import pathlib

from models import Configuration, SMSBot

logger = logging.getLogger(__name__)


def read_sms(file_path: str):
    sms_texts = []
    for txt_file in pathlib.Path(file_path).glob("*.txt"):
        logger.debug("Reading SMS from %s", txt_file)
        
        with open(txt_file, "r", encoding="utf-8") as f:
            sms = f.read()
            logger.debug("SMS: %s", sms)
            sms_texts.append(sms)

        logger.debug("Deleting %s", txt_file)
        pathlib.Path.unlink(txt_file)
    return sms_texts


async def init():
    config = Configuration("config.pkl")
    sms_texts = read_sms(config.inbox_folder)

    bot = SMSBot(config.token)

    for sms_text in sms_texts:
        await bot.send_message(config.chat_id, sms_text)


async def main():
    await init()


if __name__ == "__main__":
    logging.basicConfig(level=logging.DEBUG)
    asyncio.run(main())