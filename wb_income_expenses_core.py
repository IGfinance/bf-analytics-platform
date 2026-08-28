#!/usr/bin/env python3
"""
Парсинг, загрузка и сверка отчёта WB «Доходы и расходы».
Используется веб-формой (webapp/app.py).
"""

import re
from datetime import date
from pathlib import Path

import openpyxl
from dotenv import load_dotenv

from wb_core import get_client, SCRIPT_DIR  # get_client не дублируем

load_dotenv(SCRIPT_DIR / ".env")

# Маппинг заголовков xlsx → имена полей таблицы.
# Только «текущий период» — колонки с «(предыдущий период)» игнорируются.
_COL_MAP = {
    "Итог, ₽":                                          "total_rub",
    "Продажи, ₽":                                       "sales_rub",
    "Продажи, шт":                                      "n_sales",
    "Возвраты, ₽":                                      "returns_rub",
    "Возвраты, шт":                                     "n_returns",
    "Логистика, ₽":                                     "logistics_rub",
    "Штрафы, ₽":                                        "fines_rub",
    "Комиссия WB, ₽":                                   "commission_rub",
    "Эквайринг, ₽":                                     "acquiring_rub",
    "Потери, подмены и товары с дефектами, ₽":         "losses_rub",
    "Доплаты, ₽":                                       "bonuses_rub",
    "Программа лояльности, ₽":                         "loyalty_rub",
}

_INT_FIELDS = {"n_sales", "n_returns"}

INSERT_COLUMNS = [
    "cabinet", "period_start", "period_end",
    "n_sales", "n_returns",
    "sales_rub", "returns_rub", "logistics_rub", "fines_rub",
    "commission_rub", "acquiring_rub", "losses_rub", "bonuses_rub",
    "loyalty_rub", "total_rub",
    "source_file",
]

METRICS = [
    ("01 Кол-во продаж",  "kol_prodazh",  lambda r: r["n_sales"] - r["n_returns"],                5),
    ("02 Продажи + СПП",  "prodazhi_spp", lambda r: r["sales_rub"] + r["returns_rub"],           500),
    ("05 Комиссия ВБ",    "komissiya",    lambda r: r["commission_rub"] + r["acquiring_rub"],     500),
    ("07 Логистика",      "logistika",    lambda r: r["logistics_rub"],                           500),
    ("08 Штрафы",         "shtrafy",      lambda r: r["fines_rub"],                               100),
    ("09 Доплаты",        "doplaty",      lambda r: r["bonuses_rub"],                             100),
    ("13 Скидка Wibes",   "skidka_wibes", lambda r: r["loyalty_rub"],                             500),
    ("15 К перечислению", "k_perech",     lambda r: r["total_rub"],                              1000),
]


def parse_income_expenses(path: Path) -> dict:
    """
    Разбирает один xlsx «Доходы и расходы».
    Возвращает dict с period_start, period_end, source_file и суммами по колонкам.
    Raises ValueError если не удалось прочитать период или листы не найдены.
    """
    try:
        wb = openpyxl.load_workbook(path, data_only=True)
    except Exception as e:
        raise ValueError(f"Не удалось открыть файл «{path.name}»: {e}") from e

    try:
        ws_info = wb["Общая информация"]
    except KeyError:
        raise ValueError(f"Лист «Общая информация» не найден в «{path.name}»")

    period_start = period_end = None
    for row in ws_info.iter_rows(values_only=True):
        if row and row[0] == "Выбранный период":
            m = re.match(r"С (\d{4}-\d{2}-\d{2}) по (\d{4}-\d{2}-\d{2})", str(row[1] or ""))
            if m:
                period_start = date.fromisoformat(m.group(1))
                period_end = date.fromisoformat(m.group(2))
            break

    if not period_start or not period_end:
        raise ValueError(f"Не удалось прочитать период из «{path.name}»")

    try:
        ws_data = wb["Детальная информация"]
    except KeyError:
        raise ValueError(f"Лист «Детальная информация» не найден в «{path.name}»")

    rows = list(ws_data.iter_rows(values_only=True))
    if len(rows) < 3:
        raise ValueError(f"Слишком мало строк в «{path.name}»")

    headers = rows[1]  # строка 2 — заголовки
    col_idx = {}
    for i, h in enumerate(headers):
        if h in _COL_MAP:
            col_idx[_COL_MAP[h]] = i

    totals: dict = {field: 0.0 for field in _COL_MAP.values()}
    for row in rows[2:]:
        for field, idx in col_idx.items():
            val = row[idx]
            if isinstance(val, (int, float)):
                totals[field] += float(val)

    for field in _INT_FIELDS:
        totals[field] = int(round(totals[field]))

    return {
        "period_start": period_start,
        "period_end": period_end,
        "source_file": path.name,
        **totals,
    }
