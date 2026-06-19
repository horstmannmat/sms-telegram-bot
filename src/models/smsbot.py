# -*- coding: utf-8 -*-
from __future__ import absolute_import, annotations, print_function

import logging
from typing import Optional

import telegram

logger = logging.getLogger(__name__)

_QUIET_LOGGERS = ("httpx", "httpcore", "telegram")


def _format_chat_label(chat: telegram.Chat) -> str:
    if chat.username:
        return f"@{chat.username}"
    if chat.title:
        return chat.title
    name = " ".join(part for part in (chat.first_name, chat.last_name) if part)
    if name:
        return name
    return str(chat.id)


# pylint: disable=too-few-public-methods
class SMSBot:
    bot: telegram.Bot = None
    token: Optional[str] = None

    def __init__(self, token: str = None):
        self.token = token
        self.bot = telegram.Bot(token=token)

    async def send_message(self, chat_id: str, message: str) -> str:
        logger.debug("Sending message to %s: %s", chat_id, message)
        async with self.bot:
            sent = await self.bot.send_message(text=message, chat_id=chat_id)
        return _format_chat_label(sent.chat)
