#!/usr/bin/env python3
"""
Разбор и загрузка сводного еженедельного отчёта WB ("Отчёт о продажах по реализации").
Используется веб-формой (webapp/app.py). Зеркалирует паттерн wb_core.py.

Каждая строка xlsx = один отчёт (один report_number).
Таблица назначения: wb_report_summary.
"""

import os
import re
from pathlib import Path

import pandas as pd
import clickhouse_connect
from dotenv import load_dotenv

SCRIPT_DIR = Path(__file__).parent
load_dotenv(SCRIPT_DIR / ".env")

# Маппинг: заголовок в xlsx -> (canonical_field, ch_type)
# Порядок определяет порядок вставки — совпадает с DDL schema_wb_summary.sql
COLUMN_MAP = {
    "№ отчета":                                                         ("report_number",                  "UInt64"),
    "Юридическое лицо":                                                 ("legal_entity",                   "String"),
    "Дата начала":                                                       ("period_start",                   "Date"),
    "Дата конца":                                                        ("period_end",                     "Date"),
    "Дата формирования":                                                 ("formed_at",                     "Date"),
    "Тип отчета":                                                        ("report_type",                   "String"),
    "Продажа":                                                           ("sale",                          "Float64"),
    "В том числе Компенсация скидки по программе лояльности":           ("loyalty_discount_compensation", "Float64"),
    "К перечислению за товар":                                           ("payable_for_goods",             "Float64"),
    "Согласованная скидка, %":                                           ("agreed_discount_pct",           "Float64"),
    "Стоимость логистики":                                               ("logistics_cost",                "Float64"),
    "Стоимость хранения":                                                ("storage_cost",                  "Float64"),
    "Стоимость операций на приемке":                                     ("acceptance_cost",               "Float64"),
    "Прочие удержания/выплаты":                                          ("other_deductions",              "Float64"),
    "Общая сумма штрафов":                                               ("total_fines",                   "Float64"),
    "Корректировка Вознаграждения Вайлдберриз (ВВ)":                    ("wb_commission_correction",      "Float64"),
    "Стоимость участия в программе лояльности":                         ("loyalty_program_cost",          "Float64"),
    "Сумма баллов, удержанных по программе лояльности":                  ("loyalty_points_deducted",       "Float64"),
    "Разовое изменение срока перечисления денежных средств":             ("one_time_payment_term_change",  "Float64"),
    "Итого к оплате":                                                    ("total_payable",                 "Float64"),
    "Валюта":                                                            ("currency",                      "String"),
}

# Порядок колонок для INSERT (совпадает с ORDER BY в DDL + служебные поля)
INSERT_COLUMNS = (
    ["cabinet", "report_number", "legal_entity", "period_start", "period_end",
     "formed_at", "report_type", "currency",
     "sale", "loyalty_discount_compensation", "payable_for_goods", "agreed_discount_pct",
     "logistics_cost", "storage_cost", "acceptance_cost", "other_deductions",
     "total_fines", "wb_commission_correction", "loyalty_program_cost",
     "loyalty_points_deducted", "one_time_payment_term_change", "total_payable",
     "source_file"]
)


def _normalize(header: str) -> str:
    return re.sub(r"\s+", " ", str(header).strip())


def _coerce(value, ch_type: str):
    if pd.isna(value):
        return None
    if ch_type == "UInt64":
        try:
            return int(value)
        except (ValueError, TypeError):
            return None
    if ch_type == "Float64":
        try:
            return float(value)
        except (ValueError, TypeError):
            return None
    if ch_type == "Date":
        ts = pd.to_datetime(value, errors="coerce")
        return None if pd.isna(ts) else ts.date()
    return str(value)


def process_file(path: Path, cabinet: str, log=print) -> list[dict]:
    """
    Читает сводный xlsx, возвращает список dict — по одному на строку отчёта.
    Предупреждает о неожиданных / отсутствующих колонках.
    """
    log(f"  Читаю: {path.name}")
    try:
        df = pd.read_excel(path, sheet_name=0)
    except Exception as e:
        raise ValueError(f"Не удалось прочитать файл «{path.name}»: {e}") from e

    # Строим маппинг фактических заголовков → canonical
    actual_map = {}   # df-колонка → (canonical, ch_type)
    seen_canonicals = set()
    for col in df.columns:
        norm = _normalize(col)
        if norm in COLUMN_MAP:
            canonical, ch_type = COLUMN_MAP[norm]
            actual_map[col] = (canonical, ch_type)
            seen_canonicals.add(canonical)
        else:
            log(f"    ВНИМАНИЕ: неожиданная колонка '{col}' — игнорируется")

    # Проверяем, что все ожидаемые колонки есть
    for expected_header, (canonical, _) in COLUMN_MAP.items():
        if canonical not in seen_canonicals:
            log(f"    ВНИМАНИЕ: ожидаемая колонка '{expected_header}' не найдена в файле")

    rows = []
    for _, record in df.iterrows():
        row = {"cabinet": cabinet, "source_file": path.name}
        for col, value in record.items():
            mapping = actual_map.get(col)
            if mapping:
                canonical, ch_type = mapping
                row[canonical] = _coerce(value, ch_type)
        rows.append(row)

    log(f"    Прочитано строк: {len(rows)}")
    return rows


def get_client():
    host = os.environ["CLICKHOUSE_HOST"]
    port = int(os.environ.get("CLICKHOUSE_PORT", "8443"))
    user = os.environ.get("CLICKHOUSE_USER", "default")
    password = os.environ["CLICKHOUSE_PASSWORD"]
    database = os.environ.get("CLICKHOUSE_DATABASE", "default")
    secure = os.environ.get("CLICKHOUSE_SECURE", "1") != "0"
    return clickhouse_connect.get_client(
        host=host, port=port, username=user, password=password,
        database=database, secure=secure,
    )


def ingest_files(files: list[Path], cabinet: str, log=print) -> dict:
    """
    Загружает список сводных xlsx-файлов в wb_report_summary.
    Возвращает сводку: {'files': N, 'rows': N}.
    Повторная загрузка того же report_number перезапишет запись (ReplacingMergeTree).
    """
    all_rows = []
    for path in files:
        rows = process_file(path, cabinet, log=log)
        all_rows.extend(rows)

    if not all_rows:
        log("Нет строк для загрузки.")
        return {"files": len(files), "rows": 0}

    client = get_client()
    data = [[row.get(col) for col in INSERT_COLUMNS] for row in all_rows]
    client.insert("wb_report_summary", data, column_names=INSERT_COLUMNS)
    log(f"Загружено {len(data)} строк в wb_report_summary.")

    return {"files": len(files), "rows": len(data)}
