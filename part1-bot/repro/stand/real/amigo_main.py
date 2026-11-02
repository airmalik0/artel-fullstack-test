"""Бот формы сервера, мой код. Как у настоящего бота, настройки читает load_dotenv() без пути.

В ответе pid: по нему видно, какой процесс ответил, прежний или новый.
"""
import logging
import os
from datetime import datetime, timezone

from dotenv import load_dotenv
from telegram import Update
from telegram.ext import Application, CommandHandler, ContextTypes, MessageHandler, filters

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")


async def ping(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    age = (datetime.now(timezone.utc) - update.message.date).total_seconds()
    await update.message.reply_text(f"pong от pid {os.getpid()}, сообщение ждало {age:.0f} с")


async def echo(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    await update.message.reply_text(f"эхо от pid {os.getpid()}: {update.message.text}")


def main() -> None:
    load_dotenv()
    app = Application.builder().token(os.environ["BOT_TOKEN"]).build()
    app.add_handler(CommandHandler("ping", ping))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, echo))
    app.run_polling(allowed_updates=Update.ALL_TYPES, drop_pending_updates=True)


if __name__ == "__main__":
    main()
