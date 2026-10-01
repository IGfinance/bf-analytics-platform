"""Источник «WB, еженедельный детальный отчёт» для конвейера загрузки."""

from __future__ import annotations

from pathlib import Path

import wb_core
from upload_checks.core import CheckResult, ERROR, INFO, WARN
from upload_checks.pipeline import SourceSpec, run_ingest


def pre_file(path: Path) -> list:
    """Номер отчёта обязателен: он ключ дедупа и сверки со сводкой."""
    try:
        wb_core.extract_report_number(path.name)
    except ValueError:
        return [CheckResult(
            "report_number_missing", ERROR,
            f"В имени файла «{path.name}» нет номера отчёта (№123456789) — это точно "
            "детальный отчёт WB? Файл не загружен.")]
    return []


def existing_where(cabinet: str, rows: list) -> tuple:
    report_numbers = sorted({int(r["report_number"]) for r in rows})
    return ("cabinet = {cabinet:String} AND report_number IN {rns:Array(UInt64)}",
            {"cabinet": cabinet, "rns": report_numbers})


def post_ingest(client, cabinet: str, parsed: dict) -> dict:
    """Сверка загруженных отчётов с недельной сводкой (если она уже загружена)."""
    from reconcile_wb import run_reconciliation   # поздний импорт: reconcile_wb тянет wb_core

    results = {}
    for fname, rows in parsed.items():
        if not rows:
            continue
        rn = int(rows[0]["report_number"])
        rec = run_reconciliation(client, cabinet, rn, log=lambda *a, **k: None)
        if not rec:
            results[fname] = [CheckResult(
                "summary_reconciliation", INFO,
                f"Сводка по отчёту № {rn} не загружена — сверка не выполнена.")]
            continue
        failed = [r for r in rec if not r[10]]   # r[10] — is_ok, см. webapp/app.py FIELDS
        if failed:
            fields = ", ".join(sorted({r[5] for r in failed}))
            results[fname] = [CheckResult(
                "summary_reconciliation", ERROR,
                f"Данные записаны, но не сходятся со сводкой отчёта № {rn}: "
                f"{len(failed)} из {len(rec)} показателей ({fields}).",
                {"report_number": rn, "failed": len(failed), "total": len(rec)})]
        else:
            results[fname] = [CheckResult(
                "summary_reconciliation", INFO,
                f"Сверка со сводкой отчёта № {rn}: все {len(rec)} показателей сходятся.")]
    return results


def make_spec() -> SourceSpec:
    return SourceSpec(
        name="wb_detail", table="wb_reports", core=wb_core,
        mapping_path=wb_core.MAPPING_PATH, header_row=0,
        key_columns=["cabinet", "report_number"], unmapped_table="wb_unmapped_columns_log",
        fp_exclude=frozenset({"row_num"}),
        scope_of=lambda row: int(row["report_number"]), scope_col="report_number",
        existing_where=existing_where, pre_file=pre_file, post_ingest=post_ingest,
    )


def ingest(files: list, cabinet: str, **kwargs) -> dict:
    return run_ingest(make_spec(), files, cabinet, **kwargs)
