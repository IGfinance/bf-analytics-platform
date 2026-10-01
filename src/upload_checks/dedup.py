"""Отбор только новых строк при загрузке (ТЗ 04: дубли пропускаем, а не ругаемся).

Дубль = строка с тем же СОДЕРЖИМЫМ (значения канонических колонок), а не с тем же
именем файла. Сравнение мультимножеством: если в файле две одинаковые законные
строки, а в базе одна — вторая считается новой.
"""

from __future__ import annotations

import datetime as dt
import hashlib
from collections import Counter, defaultdict
from typing import Sequence


def _norm(value) -> str:
    if value is None:
        return ""
    if isinstance(value, bool):
        return str(int(value))
    if isinstance(value, float):
        return repr(round(value, 6))
    if isinstance(value, dt.datetime):
        return value.date().isoformat()
    if isinstance(value, dt.date):
        return value.isoformat()
    return str(value)


def fingerprint(values: Sequence) -> str:
    """Отпечаток значений в заданном порядке колонок. Одинаков для строки из файла
    (python-типы после coerce_value) и для строки, прочитанной из ClickHouse."""
    joined = "\x1f".join(_norm(v) for v in values)
    return hashlib.blake2b(joined.encode("utf-8"), digest_size=16).hexdigest()


def row_fingerprint(row: dict, cols: Sequence[str]) -> str:
    return fingerprint([row.get(c) for c in cols])


def split_new(rows: list, existing: Counter, cols: Sequence[str]) -> tuple:
    """Возвращает (новые_строки, число_дублей). existing пополняется отпечатками
    принятых строк ПОСЛЕ прохода по файлу — чтобы второй файл той же загрузки
    сверялся и с первым, но две законные одинаковые строки внутри одного файла
    не считались дублями друг друга."""
    new_rows, dups, accepted = [], 0, Counter()
    for row in rows:
        fp = row_fingerprint(row, cols)
        if existing[fp] > 0:
            existing[fp] -= 1
            dups += 1
        else:
            new_rows.append(row)
            accepted[fp] += 1
    existing.update(accepted)
    return new_rows, dups


def load_existing(client, table: str, cols: Sequence[str], where_sql: str, params: dict,
                  scope_col: str | None = None) -> dict:
    """Отпечатки уже загруженных строк (FINAL — чтобы не считать несклеенные версии).

    Возвращает {scope: Counter}. scope_col — колонка, по которой строки делятся на
    независимые группы (WB: report_number); без неё всё лежит под ключом None.
    """
    select = ([scope_col] if scope_col else []) + list(cols)
    sql = f"SELECT {', '.join(select)} FROM {table} FINAL WHERE {where_sql}"
    result: dict = defaultdict(Counter)
    for values in client.query(sql, parameters=params).result_rows:
        if scope_col:
            result[values[0]][fingerprint(values[1:])] += 1
        else:
            result[None][fingerprint(values)] += 1
    return result
