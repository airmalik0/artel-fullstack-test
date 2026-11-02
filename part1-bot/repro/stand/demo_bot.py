#!/usr/bin/env python3
"""Демо-бот стенда, замена исходного бота.

Кода работодателя здесь нет: это мой маленький бот на той же версии
python-telegram-bot (21.11.1), чтобы проверить инфраструктуру. LLM не вызывает.
"""
import logging
import os
from datetime import datetime, timezone

from telegram import Update
from telegram.ext import Application, CommandHandler, ContextTypes, MessageHandler, filters

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
log = logging.getLogger("demo_bot")


async def start(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    await update.message.reply_text("Демо-бот стенда. Команды: /help, /ping, любой текст вернётся эхом.")


async def help_(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    await update.message.reply_text("/start приветствие\n/ping проверка\nтекст вернётся эхом")


async def ping(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    age = (datetime.now(timezone.utc) - update.message.date).total_seconds()
    await update.message.reply_text(f"pong, сообщение ждало {age:.0f} с")


async def echo(update: Update, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    age = (datetime.now(timezone.utc) - update.message.date).total_seconds()
    await update.message.reply_text(f"эхо: {update.message.text} (ждало {age:.0f} с)")


async def on_error(update: object, ctx: ContextTypes.DEFAULT_TYPE) -> None:
    log.error("%s: %s", type(ctx.error).__name__, ctx.error)


def main() -> None:
    app = Application.builder().token(os.environ["BOT_TOKEN"]).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("help", help_))
    app.add_handler(CommandHandler("ping", ping))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, echo))
    app.add_error_handler(on_error)
    # Та же строка, что в исходном боте: сообщения за время простоя теряются. apply-on-server.sh её меняет.
    app.run_polling(allowed_updates=Update.ALL_TYPES, drop_pending_updates=True)


if __name__ == "__main__":
    main()
