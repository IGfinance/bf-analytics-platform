"""Источник «Ozon, отчёт Начисления» для конвейера загрузки."""

from __future__ import annotations

import ozon_core
from upload_checks.pipeline import SourceSpec, run_ingest


def existing_where(cabinet: str, rows: list) -> tuple:
    """Строки Ozon не привязаны к номеру отчёта — ищем совпадения среди строк
    кабинета в диапазоне дат файла (плюс строки без даты)."""
    dates = [r["accrual_date"] for r in rows if r.get("accrual_date") is not None]
    if not dates:
        return "cabinet = {cabinet:String}", {"cabinet": cabinet}
    return ("cabinet = {cabinet:String} AND (accrual_date IS NULL OR "
            "accrual_date BETWEEN {d_from:Date} AND {d_to:Date})",
            {"cabinet": cabinet, "d_from": min(dates), "d_to": max(dates)})


def make_spec() -> SourceSpec:
    return SourceSpec(
        name="ozon_accruals", table="ozon_reports", core=ozon_core,
        mapping_path=ozon_core.MAPPING_PATH, header_row=1,
        key_columns=["cabinet", "row_num"], unmapped_table="ozon_unmapped_columns_log",
        fp_exclude=frozenset(),
        scope_of=lambda row: None, scope_col=None,
        existing_where=existing_where,
    )


def ingest(files: list, cabinet: str, **kwargs) -> dict:
    return run_ingest(make_spec(), files, cabinet, **kwargs)
