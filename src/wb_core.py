#!/usr/bin/env python3
"""
Общая логика разбора и загрузки отчётов WB — используется и CLI-скриптом
(ingest_wb.py), и веб-формой (webapp/app.py).
"""

# Аннотации вида `str | None` требуют Python 3.10+. venv проекта на 3.13, но на
# машинах разработки встречается системный 3.9 — без отложенных аннотаций модуль
# там не импортируется вообще (2026-09-27 это заблокировало прогон
# compare_wb_summaries.py). В рантайме ничего не меняет.
from __future__ import annotations

import os
import re
from pathlib import Path

import pandas as pd
import yaml
import clickhouse_connect

SCRIPT_DIR = Path(__file__).parent
MAPPING_PATH = SCRIPT_DIR / "column_mapping_wb.yaml"

NOT_NULL_FIELDS = {"row_num": "Int32"}


def load_mapping():
    with open(MAPPING_PATH, encoding="utf-8") as f:
        raw = yaml.safe_load(f)["columns"]

    alias_to_canonical = {}
    canonical_type = {}
    for canon, info in raw.items():
        canonical_type[canon] = info["type"]
        for alias in info["aliases"]:
            norm = normalize_header(alias)
            alias_to_canonical[norm] = canon
    return alias_to_canonical, canonical_type


def normalize_header(header: str) -> str:
    """Убирает лишние пробелы, чтобы 'Размер  кВВ' и 'Размер кВВ' совпадали."""
    return re.sub(r"\s+", " ", str(header).strip())


def extract_report_number(filename: str) -> int:
    """Достаёт номер отчёта из имени файла: '...№757102688_594588...' -> 757102688."""
    match = re.search(r"№(\d+)", filename)
    if not match:
        raise ValueError(f"Не удалось найти номер отчёта в имени файла: {filename}")
    return int(match.group(1))


def coerce_value(value, ch_type: str):
    if pd.isna(value):
        return None
    if ch_type == "Int32":
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


def process_file(path: Path, cabinet: str, alias_to_canonical: dict, canonical_type: dict,
                  unmapped_seen: set, log=print) -> tuple[list[dict], list[str]]:
    log(f"  Читаю: {path.name}")
    df = pd.read_excel(path, sheet_name=0)
    report_number = extract_report_number(path.name)

    header_map = {}   # исходная колонка -> канонический код
    unmapped_raw = []
    for col in df.columns:
        norm = normalize_header(col)
        canon = alias_to_canonical.get(norm)
        if canon:
            header_map[col] = canon
        else:
            unmapped_raw.append(col)
            if norm not in unmapped_seen:
                unmapped_seen.add(norm)
                log(f"    ВНИМАНИЕ: неизвестная колонка '{col}' — уйдёт в extra_columns")

    rows = []
    for _, record in df.iterrows():
        row = {"cabinet": cabinet, "report_number": report_number, "source_file": path.name}
        extra = {}
        for col, value in record.items():
            canon = header_map.get(col)
            if canon:
                ch_type = NOT_NULL_FIELDS.get(canon, canonical_type[canon])
                row[canon] = coerce_value(value, ch_type)
            else:
                if pd.notna(value):
                    extra[str(col)] = str(value)
        row["extra_columns"] = extra
        rows.append(row)

    return rows, unmapped_raw


def get_client(database: str | None = None):
    host = os.environ["CLICKHOUSE_HOST"]
    port = int(os.environ.get("CLICKHOUSE_PORT", "8443"))
    user = os.environ.get("CLICKHOUSE_USER", "default")
    password = os.environ["CLICKHOUSE_PASSWORD"]
    if database is None:
        database = os.environ.get("CLICKHOUSE_DATABASE", "default")
    secure = os.environ.get("CLICKHOUSE_SECURE", "1") != "0"
    return clickhouse_connect.get_client(
        host=host, port=port, username=user, password=password,
        database=database, secure=secure,
    )


def ingest_files(files: list[Path], cabinet: str, log=print, database: str | None = None,
                 user_id=None, project: str | None = None) -> dict:
    """Загружает список xlsx-файлов WB в ClickHouse. Возвращает сводку по результату.

    С ТЗ 04 вся логика — в upload_checks (проверки файла до записи, пропуск
    дублей, сверка со сводкой, журнал upload_checks). При жёсткой ошибке
    проверки бросает upload_checks.core.UploadRejected, в базу ничего не пишется.

    database — БД проекта, которому принадлежит cabinet (см. g.project["slug"]
    в webapp); None — читать CLICKHOUSE_DATABASE из окружения (CLI ingest_wb.py).
    """
    from upload_checks import wb as wb_source   # поздний импорт: wb_source тянет wb_core

    return wb_source.ingest(files, cabinet, log_fn=log, database=database,
                            user_id=user_id, project=project)
