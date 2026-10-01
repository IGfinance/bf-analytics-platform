"""Общий конвейер ручной загрузки: проверки → дедуп → запись → сверка → журнал.

Порядок гарантирует «всё или ничего» для жёстких ошибок: пока все файлы не
прошли проверки, в ClickHouse не пишется ни одной строки данных.
"""

from __future__ import annotations

import logging
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Hashable, Optional

import pandas as pd

from upload_checks.core import (
    CheckResult, FileOutcome, UploadRejected, INFO, WARN, ERROR,
    check_headers, has_errors, load_column_specs, persist,
)
from upload_checks.dedup import load_existing, split_new

log = logging.getLogger(__name__)


@dataclass
class SourceSpec:
    """Описание источника для конвейера (см. upload_checks/wb.py, ozon.py)."""
    name: str                        # код источника в журнале
    table: str                       # таблица данных в БД проекта
    core: object                     # модуль с load_mapping/process_file/get_client
    mapping_path: Path
    header_row: int                  # строка заголовков в xlsx (pandas header=)
    key_columns: list                # колонки вставки перед каноническими (["cabinet", "report_number"])
    unmapped_table: str              # лог неизвестных заголовков
    fp_exclude: frozenset            # колонки, не входящие в отпечаток строки
    scope_of: Callable[[dict], Hashable]
    scope_col: Optional[str]         # колонка таблицы для scope_of (None — без групп)
    existing_where: Callable[[str, list], tuple]   # (cabinet, rows) -> (where_sql, params)
    pre_file: Callable[[Path], list] = lambda path: []
    post_ingest: Optional[Callable] = None         # (client, cabinet, parsed) -> {file: [CheckResult]}


def _read_headers(path: Path, header_row: int) -> list:
    return list(pd.read_excel(path, sheet_name=0, header=header_row, nrows=0).columns)


def run_ingest(spec: SourceSpec, files: list, cabinet: str, *, log_fn=print,
               database: str | None = None, user_id=None, project: str | None = None) -> dict:
    alias_to_canonical, canonical_type = spec.core.load_mapping()
    specs = load_column_specs(spec.mapping_path)
    client = spec.core.get_client(database=database)
    project = project or database or ""

    outcomes = {Path(p).name: FileOutcome(source_file=Path(p).name) for p in files}

    # 1. Проверки файлов до чтения данных
    for path in files:
        out = outcomes[Path(path).name]
        out.results.extend(spec.pre_file(Path(path)))
        try:
            headers = _read_headers(Path(path), spec.header_row)
        except Exception as e:
            log.exception("Файл %s не читается", path)
            out.results.append(CheckResult(
                "unreadable_file", ERROR, f"Файл не читается как .xlsx: {type(e).__name__}"))
            continue
        out.results.extend(check_headers(headers, alias_to_canonical, specs))

    def _reject():
        persist(client, outcomes.values(), user_id=user_id, project=project,
                cabinet=cabinet, source=spec.name)
        raise UploadRejected([r for o in outcomes.values() for r in o.results])

    if any(has_errors(o.results) for o in outcomes.values()):
        _reject()

    # 2. Разбор файлов (в базу ещё ничего не пишем)
    parsed, unmapped_seen, unmapped_log = {}, set(), []
    for path in files:
        name = Path(path).name
        rows, unmapped_raw = spec.core.process_file(
            Path(path), cabinet, alias_to_canonical, canonical_type, unmapped_seen, log=log_fn)
        parsed[name] = rows
        outcomes[name].rows_in_file = len(rows)
        unmapped_log.extend((name, c) for c in unmapped_raw)
        if not rows:
            outcomes[name].results.append(CheckResult(
                "empty_file", ERROR, "В файле нет строк с данными. Файл не загружен."))
    if any(has_errors(o.results) for o in outcomes.values()):
        _reject()

    # 3. Дедуп: пропускаем строки, уже лежащие в базе (по содержимому)
    fp_cols = [c for c in canonical_type if c not in spec.fp_exclude]
    all_rows = [r for rows in parsed.values() for r in rows]
    where_sql, params = spec.existing_where(cabinet, all_rows)
    existing = load_existing(client, spec.table, fp_cols, where_sql, params, spec.scope_col)
    existing_by_scope = defaultdict(Counter, existing)

    columns = list(spec.key_columns) + list(canonical_type) + ["extra_columns", "source_file"]
    to_insert = []
    for name, rows in parsed.items():
        by_scope = defaultdict(list)
        for r in rows:
            by_scope[spec.scope_of(r)].append(r)
        new_total = 0
        dup_total = 0
        for scope, scope_rows in by_scope.items():
            new_rows, dups = split_new(scope_rows, existing_by_scope[scope], fp_cols)
            to_insert.extend(new_rows)
            new_total += len(new_rows)
            dup_total += dups
        out = outcomes[name]
        out.rows_written, out.duplicates_skipped = new_total, dup_total
        if dup_total:
            msg = f"Пропущено дублей: {dup_total} из {out.rows_in_file}; записано новых: {new_total}."
            if new_total == 0:
                msg = f"Файл уже был загружен целиком: все {dup_total} строк — дубли, записывать нечего."
            out.results.append(CheckResult(
                "duplicates_skipped", INFO, msg,
                {"rows_in_file": out.rows_in_file, "duplicates": dup_total, "written": new_total}))

    # 4. Запись новых строк
    if to_insert:
        data = [[row.get(col) for col in columns] for row in to_insert]
        client.insert(spec.table, data, column_names=columns)
    log_fn(f"Загружено {len(to_insert)} новых строк в {spec.table}"
           f" (пропущено дублей: {sum(o.duplicates_skipped for o in outcomes.values())}).")
    if unmapped_log:
        client.insert(spec.unmapped_table, [[f, c] for f, c in unmapped_log],
                      column_names=["source_file", "raw_column_name"])

    # 5. Проверки после записи (сверки)
    if spec.post_ingest:
        try:
            for fname, results in spec.post_ingest(client, cabinet, parsed).items():
                outcomes[fname].results.extend(results)
        except Exception:
            log.exception("Сбой проверок после записи (%s)", spec.name)
            for o in outcomes.values():
                o.results.append(CheckResult(
                    "post_ingest_failed", WARN,
                    "Данные записаны, но проверки после записи не выполнились — см. журнал сервера."))

    persist(client, outcomes.values(), user_id=user_id, project=project,
            cabinet=cabinet, source=spec.name)

    return {
        "files": len(files),
        "rows": len(to_insert),
        "rows_in_file": sum(o.rows_in_file for o in outcomes.values()),
        "duplicates_skipped": sum(o.duplicates_skipped for o in outcomes.values()),
        "unmapped_columns": sorted(unmapped_seen),
        "outcomes": [
            {"source_file": o.source_file, "rows_in_file": o.rows_in_file,
             "rows_written": o.rows_written, "duplicates_skipped": o.duplicates_skipped,
             "results": [r.as_dict() for r in o.results]}
            for o in outcomes.values()
        ],
    }

