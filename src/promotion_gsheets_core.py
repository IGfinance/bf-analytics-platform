"""Загрузка Google-Таблицы «Продвижение CS» (CloudSix) в ClickHouse.

Три вкладки одной таблицы (ID 1OnKgJGrtfX4NaGh6ySw4O_dm6S83aKFJ2ukMzYcwD7I):

«Продв WB» — построчно по кампании, посуточно. Тех. столбец I «Артикул» —
уже готовый результат ВПР по справочнику (вкладка «Справочник», блок
«Для WB», столбцы A/B), который ведётся вручную: когда появляется новая
кампания, маркетолог вынимает артикул из её имени и прописывает в
справочник, иначе ВПР не находит соответствие.

«Продв Ozon» — построчно по SKU+кампании, за весь месяц (у Ozon нет
посуточной выгрузки продвижения). Тех. столбец U «Дата» проставляется
вручную 1-м числом месяца отчёта — просто чтобы иметь хоть помесячный
разрез. Тех. столбец V «Артикул» — ВПР по справочнику (блок «Для Ozon»,
столбцы D/E), который заполняется из SKU финотчётов Ozon.

«Справочник» — два независимых блока в одной вкладке, разделённых пустым
столбцом C: слева (A/B) Кампания→Артикул для WB, справа (D/E) SKU→Артикул
для Ozon. Оба ведутся вручную, независимой длины.

Контракт как у realt_gsheets_core.py: project_id/database аргументами,
log-колбэк, ValueError вместо sys.exit, summary-dict {rows, skipped}.
row_num — 1-based позиция строки во вкладке, ключ дедупа при перезаливке
(ReplacingMergeTree). См. src/schema_promotion.sql.
"""

from __future__ import annotations

import os
from datetime import date, datetime
from pathlib import Path

import ch_connect

SCRIPT_DIR = Path(__file__).parent

SHEETS_SCOPE = ["https://www.googleapis.com/auth/spreadsheets.readonly"]

WB_PROMOTION_SHEET_NAME = "Продв WB"
WB_PROMOTION_SOURCE = "gsheet:Продв WB"
WB_PROMOTION_COLUMNS = [
    "project_id", "campaign_id", "campaign", "section", "promo_date",
    "write_off_source", "amount", "document_number", "article", "row_num",
    "source_file",
]
# Позиции колонок во вкладке «Продв WB» (0-based)
_WB_POS = {
    "campaign_id": 0, "campaign": 1, "section": 2, "promo_date": 3,
    "write_off_source": 4, "amount": 5, "document_number": 6, "article": 8,
}


def _cell(row: list, idx: int) -> str:
    return row[idx].strip() if idx < len(row) else ""


def _num(value: str):
    """'120 000,00' / '134\\xa0400' / '-2 617,00' / '-' → float | None."""
    value = (value or "").replace("\xa0", "").replace(" ", "").replace(",", ".").strip()
    if not value or value == "-":
        return None
    try:
        return float(value)
    except ValueError:
        return None


def _date(value: str):
    value = (value or "").strip()
    try:
        return datetime.strptime(value, "%d.%m.%Y").date()
    except ValueError:
        return None


def parse_wb_promotion(values: list[list[str]]) -> tuple[list[dict], int]:
    """Вкладка «Продв WB» → записи. Возвращает (строки, пропущено).

    Строка — данные, только если заполнена «Кампания» (столбец B); иначе
    (пустая/декоративная строка) — пропуск. row_num — 1-based позиция строки
    во вкладке (включая заголовок), ключ дедупа при перезаливке.
    """
    rows, skipped = [], 0
    for row_num, raw in enumerate(values[1:], start=2):
        campaign = _cell(raw, _WB_POS["campaign"])
        if not campaign:
            skipped += 1
            continue

        rec = {"row_num": row_num, "source_file": WB_PROMOTION_SOURCE, "campaign": campaign}
        rec["campaign_id"] = _cell(raw, _WB_POS["campaign_id"]) or None
        rec["section"] = _cell(raw, _WB_POS["section"]) or None
        rec["promo_date"] = _date(_cell(raw, _WB_POS["promo_date"]))
        rec["write_off_source"] = _cell(raw, _WB_POS["write_off_source"]) or None
        rec["amount"] = _num(_cell(raw, _WB_POS["amount"]))
        rec["document_number"] = _cell(raw, _WB_POS["document_number"]) or None
        rec["article"] = _cell(raw, _WB_POS["article"]) or None
        rows.append(rec)

    return rows, skipped
