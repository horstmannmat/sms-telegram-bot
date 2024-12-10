# -*- coding: utf-8 -*-
from __future__ import absolute_import, annotations, print_function

import logging
import pickle

logger = logging.getLogger(__name__)


class Configuration:
    chat_id: str = None
    token: str = None
    inbox_folder: str = None

    def __init__(self, file_path: str = "config.pkl"):
        self.file_path = file_path
        self._init_config()

    def __getstate__(self):
        state = self.__dict__.copy()
        # Don't pickle file_path
        del state["file_path"]
        return state

    def _init_config(self):
        logger.debug("Loading config from %s", self.file_path)

        with open(self.file_path, "rb") as config_file:
            tmp_config_dict = pickle.load(config_file).__dict__
        logger.debug("Loaded config: %s", tmp_config_dict)

        self.__dict__.update(tmp_config_dict)

        write_config = False
        if not self.token:
            self.token = input("Enter your Token API KEY: ")
            write_config = True

        if not self.chat_id:
            self.chat_id = input("Enter your Chat ID: ")
            write_config = True

        if not self.inbox_folder:
            self.inbox_folder = input(
                "Enter the full path your Inbox Folder: "
            )
            write_config = True

        if write_config:
            self.write(self.file_path)

    def write(self, file_path: str):
        self.file_path = file_path
        # Don't pickle file_path
        with open(file_path, "wb") as config_file:
            pickle.dump(self, config_file)
