#!/usr/bin/env python3
"""
Сверка сводного еженедельного отчёта WB с детальными данными в wb_reports.

Для каждой пары (cabinet, report_number) из wb_report_summary:
  — агрегирует wb_reports одним SELECT по всем правилам из YAML,
  — сравнивает с значениями сводного отчёта,
  — пишет результат в wb_reconciliation_results.

Примеры запуска:
    python3 reconcile_wb.py --cabinet AcmeShop
    python3 reconcile_wb.py --cabinet AcmeShop --report-number 595018780
    python3 reconcile_wb.py --cabinet AcmeShop --verbose
"""

import argparse
from typing import Callable

import yaml
from dotenv import load_dotenv

from wb_core import get_client, SCRIPT_DIR

load_dotenv(SCRIPT_DIR.parent / ".env")  # .env лежит в корне репозитория, на уровень выше src/

RULES_PATH = SCRIPT_DIR / "reconciliation_rules_wb.yaml"

# Маппинг summary_column (из YAML) → поле в таблице wb_report_summary
SUMMARY_FIELD_MAP = {
    "Продажа":                                                            "sale",
    "В том числе Компенсация скидки по программе лояльности":            "loyalty_discount_compensation",
    "К перечислению за товар":                                            "payable_for_goods",
    "Стоимость логистики":                                                "logistics_cost",
    "Стоимость хранения":                                                 "storage_cost",
    "Стоимость операций на приемке":                                      "acceptance_cost",
    "Прочие удержания/выплаты":                                           "other_deductions",
    "Общая сумма штрафов":                                                "total_fines",
    "Корректировка Вознаграждения Вайлдберриз (ВВ)":                     "wb_commission_correction",
    "Стоимость участия в программе лояльности":                          "loyalty_program_cost",
    "Сумма баллов, удержанных по программе лояльности":                  "loyalty_points_deducted",
    "Итого к оплате":                                                     "total_payable",
}


def load_rules() -> list[dict]:
    with open(RULES_PATH, encoding="utf-8") as f:
        return yaml.safe_load(f)["rules"]


def _build_agg_sql(rules: list[dict], cabinet: str, report_number: int) -> tuple[str, dict]:
    """Собирает один SELECT с агрегатами по всем правилам для заданного отчёта."""
    exprs = [rule["ch_expression"].strip() for rule in rules]
    select_clause = ",\n    ".join(exprs)
    sql = (
        f"SELECT\n    {select_clause}\n"
        f"FROM wb_reports FINAL\n"
        f"WHERE cabinet = {{cabinet:String}} AND report_number = {{report_number:UInt64}}"
    )
    return sql, {"cabinet": cabinet, "report_number": report_number}


def _has_raw_data(client, cabinet: str, report_number: int) -> bool:
    """Проверяет, есть ли хотя бы одна строка в wb_reports для данного отчёта."""
    rows = client.query(
        "SELECT count() FROM wb_reports FINAL "
        "WHERE cabinet = {cabinet:String} AND report_number = {report_number:UInt64}",
        parameters={"cabinet": cabinet, "report_number": report_number},
    ).result_rows
    return rows[0][0] > 0


def _compute_status(is_ok: int, has_raw: bool) -> str:
    if not has_raw:
        return "missing_raw"   # сводный есть, сырых данных нет
    return "ok" if is_ok else "mismatch"


def run_reconciliation(client, cabinet: str, report_number: int | None = None,
                        verbose: bool = False,
                        log: Callable = print) -> list[tuple]:
    rules = load_rules()

    # Поля из wb_report_summary, которые нам нужны
    summary_fields = ["report_number", "report_type", "period_start", "period_end"] + [
        SUMMARY_FIELD_MAP[r["summary_column"]] for r in rules
        if r["summary_column"] in SUMMARY_FIELD_MAP
    ]
    seen = set()
    unique_summary_fields = []
    for f in summary_fields:
        if f not in seen:
            seen.add(f)
            unique_summary_fields.append(f)

    where = "cabinet = {cabinet:String}"
    where_params = {"cabinet": cabinet}
    if report_number is not None:
        where += " AND report_number = {report_number:UInt64}"
        where_params["report_number"] = report_number

    summary_rows = client.query(
        f"SELECT {', '.join(unique_summary_fields)} FROM wb_report_summary FINAL "
        f"WHERE {where} ORDER BY report_number",
        parameters=where_params,
    ).result_rows

    if not summary_rows:
        log(f"Нет данных в wb_report_summary для cabinet='{cabinet}'"
            + (f", report_number={report_number}" if report_number else ""))
        return []

    log(f"Сверка для кабинета '{cabinet}': {len(summary_rows)} отчёт(ов)\n")

    all_result_rows = []

    for summary_row in summary_rows:
        summary = dict(zip(unique_summary_fields, summary_row))
        rn = summary["report_number"]
        rtype = summary.get("report_type") or "—"
        p_start = summary.get("period_start")
        p_end = summary.get("period_end")

        has_raw = _has_raw_data(client, cabinet, rn)
        log(f"  № {rn}  [{rtype}]  {p_start} — {p_end}"
            + ("  [НЕТ СЫРЫХ ДАННЫХ]" if not has_raw else ""))

        agg_sql, agg_params = _build_agg_sql(rules, cabinet, rn)
        agg_row = client.query(agg_sql, parameters=agg_params).result_rows
        ch_values = list(agg_row[0]) if agg_row else [None] * len(rules)

        for i, rule in enumerate(rules):
            col = rule["summary_column"]
            summary_field = SUMMARY_FIELD_MAP.get(col)
            if summary_field is None:
                continue

            s_val = summary.get(summary_field)
            ch_val = ch_values[i]

            s_val_f = float(s_val) if s_val is not None else 0.0
            ch_val_f = float(ch_val) if ch_val is not None else 0.0
            diff = abs(s_val_f - ch_val_f)
            tolerance = float(rule["tolerance"])
            is_ok = 1 if diff <= tolerance else 0
            status = _compute_status(is_ok, has_raw)

            if verbose or status != "ok":
                label = {"ok": "OK", "mismatch": f"MISMATCH {diff:.2f}",
                         "missing_raw": "НЕТ СЫРЫХ"}.get(status, status)
                log(f"    [{label:>22}] {col[:50]:<50}  сводный={s_val_f:.2f}  CH={ch_val_f:.2f}")

            all_result_rows.append((
                cabinet, rn, rtype, p_start, p_end,
                col, s_val_f, ch_val_f, diff, tolerance, is_ok, status,
            ))

        if verbose:
            log("")

    # --- missing_summary: report_number есть в wb_reports, но нет в wb_report_summary ---
    raw_where = "cabinet = {cabinet:String}"
    raw_where_params = {"cabinet": cabinet}
    if report_number is not None:
        raw_where += " AND report_number = {report_number:UInt64}"
        raw_where_params["report_number"] = report_number

    raw_rns = {
        r[0] for r in client.query(
            f"SELECT DISTINCT report_number FROM wb_reports FINAL WHERE {raw_where}",
            parameters=raw_where_params,
        ).result_rows
    }
    summary_rns = {r["report_number"] for r in
                   [dict(zip(unique_summary_fields, row)) for row in summary_rows]}

    for rn in sorted(raw_rns - summary_rns):
        log(f"  № {rn}  [НЕТ В СВОДНОМ]")
        all_result_rows.append((
            cabinet, rn, None, None, None,
            "*", None, None, None, 0.0, 0, "missing_summary",
        ))

    # --- Запись результатов ---
    client.insert(
        "wb_reconciliation_results",
        all_result_rows,
        column_names=[
            "cabinet", "report_number", "report_type", "period_start", "period_end",
            "field_name", "expected_value", "actual_value", "diff", "tolerance", "is_ok", "status",
        ],
    )

    total = len(all_result_rows)
    by_status = {}
    for r in all_result_rows:
        by_status[r[-1]] = by_status.get(r[-1], 0) + 1

    log(f"\nИтого: {total} проверок")
    for s, n in sorted(by_status.items()):
        log(f"  {s}: {n}")

    return all_result_rows


def main():
    parser = argparse.ArgumentParser(description="Сверка сводного отчёта WB с данными ClickHouse")
    parser.add_argument("--cabinet", required=True, help="Название кабинета")
    parser.add_argument("--report-number", type=int, default=None,
                        help="Сверить только один отчёт (необязательно)")
    parser.add_argument("--verbose", action="store_true",
                        help="Показывать все поля, включая совпавшие")
    args = parser.parse_args()

    try:
        client = get_client()
        run_reconciliation(client, args.cabinet, args.report_number, args.verbose)
    except Exception as e:
        print(f"Ошибка: {e}")
        raise SystemExit(1)


if __name__ == "__main__":
    main()
