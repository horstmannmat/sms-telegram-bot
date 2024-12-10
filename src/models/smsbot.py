# -*- coding: utf-8 -*-
from __future__ import absolute_import, annotations, print_function

import logging

import telegram

logger = logging.getLogger(__name__)


# pylint: disable=too-few-public-methods
class SMSBot:
    bot: telegram.Bot = None
    token: str = None

    def __init__(self, token: str = None):
        self.token = token
        self.bot = telegram.Bot(token=token)

    async def send_message(self, chat_id: str, message: str):
        logger.debug("Sending message to %s: %s", chat_id, message)
        async with self.bot:
            await self.bot.send_message(text=message, chat_id=chat_id)
