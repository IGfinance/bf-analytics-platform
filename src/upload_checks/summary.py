"""Источник «WB, еженедельный сводный отчёт» для проверок загрузки.

До 2026-10-04 у этой загрузки не было проверок вообще (ТЗ 04 закрыло детальный WB и Ozon):
чужой xlsx разбирался в тысячи «строк» с пустыми полями, а разбор лишь писал в лог «ожидаемая
колонка не найдена». Правила те же, что у остальных дверей: жёсткая ошибка — ДО записи в базу.

Основа набора обязательных колонок — реальные данные: у 506 строк сводок из настоящего файла все
20 колонок заполнены всегда, то есть настоящий файл содержит их полностью.
"""

from __future__ import annotations

from pathlib import Path

import pandas as pd

import wb_summary_core as core
from upload_checks.core import (
    CheckResult, FileOutcome, UploadRejected, ERROR, INFO, WARN, has_errors, persist,
)

SOURCE = "wb_summary"

# Без этих колонок строка не имеет смысла: ключ отчёта и период нужны сверке.
KEY_COLUMNS = {"report_number", "period_start", "period_end"}


def _canonical_to_header() -> dict:
    return {canon: header for header, (canon, _t) in core.COLUMN_MAP.items()}


def _detail_report_hint(headers: list) -> bool:
    """Похоже ли на ДЕТАЛЬНЫЙ отчёт WB (частая ошибка — загрузить его в дверь сводки)."""
    try:
        import wb_core
        alias_to_canonical, _ = wb_core.load_mapping()
    except Exception:  # подсказка не должна ломать проверку
        return False
    hits = sum(1 for h in headers if core._normalize(h) in alias_to_canonical)
    return hits >= 10


def check_file(path: Path) -> list:
    """Проверки одного файла до чтения данных: заголовки и наличие строк с номером отчёта."""
    path = Path(path)
    try:
        headers = list(pd.read_excel(path, sheet_name=0, nrows=0).columns)
    except Exception as e:
        return [CheckResult("unreadable_file", ERROR,
                            f"Файл не читается как .xlsx: {type(e).__name__}. Файл не загружен.")]

    found = {core.COLUMN_MAP[core._normalize(h)][0] for h in headers if core._normalize(h) in core.COLUMN_MAP}
    unknown = [str(h) for h in headers if core._normalize(h) not in core.COLUMN_MAP]
    c2h = _canonical_to_header()

    must = [c for c in core.COLUMN_MAP.values() if c[0] in KEY_COLUMNS or c[1] == "Float64"]
    missing_must = [c2h[canon] for canon, _t in must if canon not in found]
    missing_other = [c2h[c] for c in c2h if c not in found and c not in {m[0] for m in must}]

    results = []
    if missing_must:
        hint = (" Похоже, это детальный отчёт WB — загрузите его через «Детальный отчёт WB»."
                if _detail_report_hint(headers) else "")
        results.append(CheckResult(
            "not_a_summary_report", ERROR,
            "Файл не похож на «Еженедельный сводный отчёт» WB: нет обязательных колонок — "
            + ", ".join(missing_must[:8]) + ("…" if len(missing_must) > 8 else "") + "." + hint
            + " Файл не загружен.",
            {"missing": missing_must}))
        return results
    if missing_other:
        results.append(CheckResult(
            "missing_columns", WARN, "В файле нет колонок: " + ", ".join(missing_other),
            {"columns": missing_other}))
    if unknown:
        results.append(CheckResult(
            "unmapped_columns", WARN,
            "Неизвестные колонки (в загрузку не попадают): " + ", ".join(unknown), {"columns": unknown}))

    try:
        df = pd.read_excel(path, sheet_name=0)
    except Exception as e:
        results.append(CheckResult("unreadable_file", ERROR, f"Файл не читается: {type(e).__name__}."))
        return results
    num_col = next(h for h in headers if core._normalize(h) == c2h["report_number"])
    valid = pd.to_numeric(df[num_col], errors="coerce").notna().sum()
    non_empty = int(df.dropna(how="all").shape[0])
    if valid == 0:
        results.append(CheckResult(
            "empty_file", ERROR,
            "В файле нет ни одной строки с номером отчёта. Файл не загружен.", {"rows": non_empty}))
    elif non_empty > valid:
        results.append(CheckResult(
            "rows_without_report_number", WARN,
            f"{non_empty - int(valid)} строк без номера отчёта пропущены (например, итоговая строка).",
            {"skipped": non_empty - int(valid)}))
    return results


def ingest(files: list, cabinet: str, *, log=print, database: str | None = None,
           user_id=None, project: str | None = None, log_fn=None) -> dict:
    """Проверяет файлы и только потом пишет в wb_report_summary.

    Жёсткая ошибка любого файла отклоняет весь пакет (UploadRejected), в базу ничего не пишется."""
    log = log_fn or log
    outcomes = {Path(p).name: FileOutcome(source_file=Path(p).name) for p in files}
    for p in files:
        outcomes[Path(p).name].results.extend(check_file(p))

    def _persist():
        try:
            persist(core.get_client(database=database), outcomes.values(), user_id=user_id,
                    project=project or database or "", cabinet=cabinet, source=SOURCE)
        except Exception:  # журнал не должен ломать ответ пользователю
            pass

    if any(has_errors(o.results) for o in outcomes.values()):
        _persist()
        raise UploadRejected([r for o in outcomes.values() for r in o.results])

    result = core.ingest_files([Path(p) for p in files], cabinet, log=log, database=database)
    for o in outcomes.values():
        o.rows_written = result["rows"] if len(outcomes) == 1 else 0
    _persist()
    result["outcomes"] = [
        {"source_file": o.source_file, "results": [r.as_dict() for r in o.results]}
        for o in outcomes.values()]
    return result
