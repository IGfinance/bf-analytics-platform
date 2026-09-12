"""Парсер ручных выгрузок Google-Таблиц Реальта (зарплаты, расходы по
статьям) -> ClickHouse.

TODO(Илья): формат согласовать с реальными файлами перед реализацией — см.
schema_realt_gsheets.sql. Два независимых входа (ingest_payroll /
ingest_expenses), т.к. это разные сущности и разные веб-формы.
"""

from __future__ import annotations

from pathlib import Path


def get_client():
    """Тот же паттерн, что wb_core.get_client."""
    raise NotImplementedError


def ingest_payroll(paths: list[Path], project_id: int, log=print) -> dict:
    """Парсит выгрузку Google-Таблицы «зарплаты» и пишет в realt_payroll.

    Контракт — как klientiks_core.ingest_files: project_id аргументом,
    log вместо print, исключения вместо sys.exit, возвращает summary
    (например {"rows": <int>}).
    """
    raise NotImplementedError


def ingest_expenses(paths: list[Path], project_id: int, log=print) -> dict:
    """Парсит выгрузку Google-Таблицы «расходы по статьям» и пишет в
    realt_expenses. Контракт — как ingest_payroll."""
    raise NotImplementedError
