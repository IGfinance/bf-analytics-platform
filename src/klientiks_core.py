"""Парсер выгрузки Клиентикс (учётная система клиник) → ClickHouse.

Формат: CSV, кодировка cp1251, разделитель ';', 19 колонок. Структура
нестабильна — часть строк приходит с 18 колонками (пропущена пустая колонка
в «хвосте»), поэтому birth_date/gender определяются по содержимому, а не по
фиксированной позиции. Голова (0–10) стабильна и читается по позициям.
Нераспознанный хвост уходит в extra_columns. См. schema_klientiks.sql.

Паттерн — как wb_core.py/bank_statement_1c.py: parse-функция отдельно от
ingest_files, чтобы переиспользовать и из CLI (ingest_klientiks.py), и из
webapp/app.py. PII (имя/телефон) хранится в БД, но НИКОГДА не логируется.
"""

from __future__ import annotations

import csv
import os
import re
from datetime import datetime
from pathlib import Path

import clickhouse_connect

SCRIPT_DIR = Path(__file__).parent

COLUMNS = [
    "project_id", "visit_start", "doctor", "doctor_role", "service",
    "client_name", "client_source", "client_phone", "visit_modified",
    "cancel_reason", "card_number", "comment", "rescheduled", "amount",
    "completed_count", "psychologist_category", "psychiatrist_category",
    "birth_date", "gender", "extra_columns", "row_num", "source_file",
]

# Голова выгрузки — стабильные позиции 0–10 (до «Перезаписан»)
HEAD = [
    "visit_start", "doctor", "doctor_role", "service", "client_name",
    "client_source", "client_phone", "visit_modified", "cancel_reason",
    "card_number", "comment",
]

_BIRTH_RE = re.compile(r"^\d{2}\.\d{2}\.\d{4}$")
_GENDERS = {"male", "female"}


def _parse_dt(value: str):
    """'2025-04-24 21:00:00' или с микросекундами '...50.179216' → datetime."""
    value = (value or "").strip()
    if not value:
        return None
    value = value.split(".", 1)[0]  # обрезаем доли секунды (ClickHouse DateTime без них)
    try:
        return datetime.strptime(value, "%Y-%m-%d %H:%M:%S")
    except ValueError:
        return None


def _parse_birth(value: str):
    value = (value or "").strip()
    if not _BIRTH_RE.match(value):
        return None
    try:
        return datetime.strptime(value, "%d.%m.%Y").date()
    except ValueError:
        return None


def _parse_float(value: str):
    value = (value or "").strip().replace(",", ".")
    if not value:
        return None
    try:
        return float(value)
    except ValueError:
        return None


def _parse_int(value: str):
    value = (value or "").strip()
    if not value or not value.isdigit():
        return None
    return int(value)


def _clean_cat(value: str):
    """Категория по позиции, но не значение-дата/пол (сдвиг колонок)."""
    value = (value or "").strip()
    if not value or value.lower() in _GENDERS or _BIRTH_RE.match(value):
        return None
    return value


def parse_file(path: Path) -> tuple[list[dict], int]:
    """Разбирает один CSV-файл Клиентикс.

    Возвращает (строки, число пропущенных). Пропускаются строки короче головы
    (< 11 полей) — «мусор» от многострочных значений; их число возвращается,
    чтобы вызывающий код показал его, а не потерял тихо.
    """
    rows: list[dict] = []
    skipped = 0
    with open(path, encoding="cp1251", newline="") as f:
        reader = csv.reader(f, delimiter=";")
        next(reader, None)  # заголовок
        for row_num, raw in enumerate(reader, start=1):
            if len(raw) < len(HEAD):
                skipped += 1
                continue

            rec = {name: (raw[i].strip() or None) for i, name in enumerate(HEAD)}
            rec["card_number"] = raw[9].strip()  # ID клиента — не Nullable, пустая строка допустима
            rec["visit_start"] = _parse_dt(raw[0])
            rec["visit_modified"] = _parse_dt(raw[7])

            tail = raw[len(HEAD):]  # с позиции 11 (Перезаписан) и дальше
            rec["rescheduled"] = (tail[0].strip() or None) if len(tail) > 0 else None
            rec["amount"] = _parse_float(tail[1]) if len(tail) > 1 else None
            rec["completed_count"] = _parse_int(tail[2]) if len(tail) > 2 else None

            # birth_date/gender — по содержимому (устойчиво к сдвигу колонок)
            rec["birth_date"] = next((_parse_birth(v) for v in tail if _parse_birth(v)), None)
            rec["gender"] = next((v.strip().lower() for v in tail if v.strip().lower() in _GENDERS), None)

            # категории — по позициям (best-effort); НЕ захватываем значения,
            # которые на самом деле birth_date/gender (сдвиг колонок в 18-кол строках)
            rec["psychologist_category"] = _clean_cat(tail[3]) if len(tail) > 3 else None
            rec["psychiatrist_category"] = _clean_cat(tail[4]) if len(tail) > 4 else None

            used = {rec["gender"], rec["rescheduled"]}
            extra = {}
            for j, v in enumerate(tail):
                v = v.strip()
                if not v or v.lower() in _GENDERS or _BIRTH_RE.match(v):
                    continue
                if j in (0, 1, 2, 3, 4):  # уже разобраны в канонические поля
                    continue
                extra[f"tail_{j}"] = v
            rec["extra_columns"] = extra

            rec["row_num"] = row_num
            rec["source_file"] = path.name
            rows.append(rec)

    return rows, skipped


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


def ingest_files(files: list[Path], project_id: int, log=print, database: str | None = None) -> dict:
    """Парсит CSV-файлы Клиентикс и пишет в klientiks_operations. Возвращает сводку.

    Контракт как у wb_core/bank_statement_1c.ingest_files: project_id и database
    передаются явно, лог через log-колбэк, при пустом результате — ValueError
    (никаких sys.exit). Пропущенные «мусорные» строки не теряются тихо —
    их число попадает в лог и в summary. PII в лог не пишется.
    """
    all_rows = []
    total_skipped = 0
    for path in files:
        log(f"  Читаю: {path.name}")
        rows, skipped = parse_file(path)
        if skipped:
            log(f"    Пропущено нечитаемых строк (неполная структура): {skipped}")
        all_rows.extend(rows)
        total_skipped += skipped

    if not all_rows:
        raise ValueError("Не найдено ни одной строки визита")

    for row in all_rows:
        row["project_id"] = project_id

    client = get_client(database=database)
    data = [[row.get(col) for col in COLUMNS] for row in all_rows]
    client.insert("klientiks_operations", data, column_names=COLUMNS)
    log(f"Загружено {len(data)} строк в klientiks_operations.")

    return {
        "files": len(files),
        "rows": len(data),
        "skipped": total_skipped,
    }
