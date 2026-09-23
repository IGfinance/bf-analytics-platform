#!/usr/bin/env python3
"""
Сверка "Ozon cash-flow-statement (ozon_cashflow_reconciled_month)" с "ручная
выгрузка .xlsx Начисления (ozon_reports)" по кабинету — аналог
compare_ozon_sources.py для нового источника (/v1/finance/cash-flow-statement/list
вместо мёртвого /v3/finance/transaction/list).

reconciled_total уже учитывает три поправки к сырым данным Ozon (loan,
агентские аномалии AgencyFeeForSale/PointsAwarded, задвоение статей логистики)
— см. schema_ozon_cashflow_reconciled.sql. Оставшееся расхождение, если оно
есть, — как правило "Упаковка товара партнёрами"/"Временное размещение товара
партнерами" (FBO-поставочные сборы, которых физически нет ни в cash-flow-
statement, ни в accrual/postings — задокументированный пробел покрытия,
см. историю разбора CloudSix).

Пример:
    python3 compare_ozon_cashflow.py --cabinet CloudSix
"""

import argparse
from pathlib import Path

from dotenv import load_dotenv

SCRIPT_DIR = Path(__file__).parent
load_dotenv(SCRIPT_DIR.parent / ".env")

from ozon_realization_core import get_client  # noqa: E402

TOLERANCE_RUB = 0.01  # сходимость до копейки, по требованию — строже, чем 1₽ у compare_ozon_sources.py.
# Известный неустранимый остаток (FBO-поставочные сборы, см. schema_ozon_cashflow_reconciled.sql)
# при таком допуске будет честно показывать ❌ — это не баг статуса, а реальный пробел источника.


def fetch_xlsx_by_month(client, cabinet: str) -> dict:
    sql = """
        SELECT toStartOfMonth(accrual_date) AS month, sum(total_amount) AS total
        FROM ozon_reports FINAL
        WHERE cabinet = {cabinet:String}
        GROUP BY month
        ORDER BY month
    """
    rows = client.query(sql, parameters={"cabinet": cabinet}).result_rows
    return {r[0]: float(r[1] or 0) for r in rows}


def fetch_cashflow_by_month(client, cabinet: str) -> dict:
    sql = """
        SELECT month, reconciled_total
        FROM ozon_cashflow_reconciled_month
        WHERE cabinet = {cabinet:String}
        ORDER BY month
    """
    rows = client.query(sql, parameters={"cabinet": cabinet}).result_rows
    return {r[0]: float(r[1] or 0) for r in rows}


def run_comparison(client, cabinet: str, log=print) -> list[tuple]:
    xlsx_by_month = fetch_xlsx_by_month(client, cabinet)
    api_by_month = fetch_cashflow_by_month(client, cabinet)
    months = sorted(set(xlsx_by_month) | set(api_by_month))

    if not months:
        log(f"Нет данных ни в ozon_reports, ни в ozon_cashflow_periods для cabinet='{cabinet}'")
        return []

    log(f"Сверка Ozon cash-flow-statement vs .xlsx для кабинета '{cabinet}': {len(months)} месяц(ев)\n")

    result_rows = []
    for month in months:
        x_val = xlsx_by_month.get(month, 0.0)
        a_val = api_by_month.get(month, 0.0)
        missing = "  [НЕТ В API]" if month not in api_by_month else ("  [НЕТ В .XLSX]" if month not in xlsx_by_month else "")
        diff = abs(x_val - a_val)
        diff_pct = (diff / abs(x_val) * 100) if x_val else None
        is_ok = 1 if diff < TOLERANCE_RUB else 0

        label = "OK" if is_ok else f"MISMATCH {diff:.2f}"
        log(f"  {month}  [{label:>18}]  xlsx={x_val:>14,.2f}  cashflow={a_val:>14,.2f}{missing}")

        result_rows.append((
            cabinet, "ozon", month, "total_amount_vs_cashflow_reconciled", x_val, a_val, diff, diff_pct, TOLERANCE_RUB, is_ok,
        ))

    client.insert(
        "api_reconciliation_results",
        result_rows,
        column_names=["cabinet", "platform", "period_month", "metric",
                       "xlsx_value", "api_value", "diff", "diff_pct", "tolerance", "is_ok"],
    )

    ok_count = sum(r[-1] for r in result_rows)
    log(f"\nИтого: {len(result_rows)} проверок, совпало: {ok_count}, разошлось: {len(result_rows) - ok_count}")
    return result_rows


def main():
    parser = argparse.ArgumentParser(description="Сверка Ozon cash-flow-statement с ручной выгрузкой .xlsx")
    parser.add_argument("--cabinet", required=True, help="Название кабинета")
    args = parser.parse_args()

    client = get_client()
    run_comparison(client, args.cabinet)


if __name__ == "__main__":
    main()
