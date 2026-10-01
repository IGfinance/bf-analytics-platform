"""load_dotenv, который не падает, если .env недоступен этому пользователю.

На проде веб-сервис работает от www-data и корневой .env ему НЕ читать (там пароль админа
ClickHouse, ключи площадок, реквизиты SSH). Прямой dotenv.load_dotenv на недоступном файле
бросает PermissionError при импорте модуля и роняет воркеры (так было 2026-10-02). Весь код в
src/ грузит .env только через эту обёртку (tests/test_ch_connect.py следит за этим).
"""

from __future__ import annotations

import dotenv


def load_dotenv(*args, **kwargs) -> bool:
    try:
        return dotenv.load_dotenv(*args, **kwargs)
    except OSError:      # нет доступа к файлу — окружение берётся из того, что уже задано
        return False
