"""Парсер выгрузки Клиентикс (учётная система клиник) -> ClickHouse.

TODO(Илья): формат выгрузки уточнить по реальному файлу от Реальта — см.
schema_klientiks.sql. Паттерн — как wb_core.py/bank_statement_1c.py:
parse-функция отдельно от ingest_files, чтобы переиспользовать и из CLI
(ingest_klientiks.py), и из webapp/app.py.
"""

from __future__ import annotations

from pathlib import Path

COLUMNS = [
    "project_id", "operation_date", "extra_columns", "row_num", "source_file",
]  # TODO(Илья): дополнить реальными колонками из schema_klientiks.sql


def get_client():
    """Тот же паттерн, что wb_core.get_client — конфигурируемое подключение
    (host/port/user/password/database из ENV), без хардкода."""
    raise NotImplementedError


def parse_file(path: Path) -> list[dict]:
    """Разбирает один файл выгрузки Клиентикс в список строк-словарей."""
    raise NotImplementedError


def ingest_files(paths: list[Path], project_id: int, log=print) -> dict:
    """Парсит файлы и пишет в klientiks_operations.

    Контракт (как wb_core.ingest_files, чтобы вызывать из webapp):
    - project_id передаётся явно аргументом, не читается из глобальной
      переменной/env — один и тот же процесс обслуживает несколько проектов;
    - лог прогресса — через log(...), не print (в вебе печатать некуда);
    - при ошибке (битый файл, отсутствует ожидаемая колонка и т.п.) кидает
      исключение — вызывающий код сам решает, как показать ошибку
      пользователю, никаких sys.exit;
    - возвращает summary, например {"rows": <int>}.
    """
    raise NotImplementedError
