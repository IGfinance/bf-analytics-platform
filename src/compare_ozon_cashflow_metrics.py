#!/usr/bin/env python3
"""
Сверка Ozon "новый API (cash-flow) vs .xlsx" ПО КАЖДОЙ МЕТРИКЕ модели
(ozon_metrics_by_cabinet_month vs ozon_metrics_by_cabinet_month_cashflow_api,
см. schema_ozon_cashflow_metrics_views.sql) — аналог compare_ozon_metrics.py
для нового источника (/v1/finance/cash-flow-statement/list вместо мёртвого
/v3/finance/transaction/list).

sales_with_spp/commission/returns_corrections по отдельности не сверяются —
у cash-flow-statement нет их раздельного аналога, есть только объединённая
payable_for_goods (см. комментарий в начале schema_ozon_cashflow_metrics_views.sql).
Итоговая сумма (payable_total) не пишется этим скриптом — она уже считается
compare_ozon_cashflow.py под именем метрики total_amount_vs_cashflow_reconciled,
дублировать не нужно.

Пример:
    python3 compare_ozon_cashflow_metrics.py --cabinet CloudSix
"""

import argparse
from pathlib import Path

from dotenv import load_dotenv

SCRIPT_DIR = Path(__file__).parent
load_dotenv(SCRIPT_DIR.parent / ".env")

from ozon_cashflow_core import get_client  # noqa: E402

TOLERANCE_RUB = 1.0  # OK только при расхождении < 1₽ — см. compare_ozon_metrics.py

METRICS = [
    "payable_for_goods",
    "logistics_cost",
    "last_mile_cost",
    "fines",
    "surcharges",
    "storage_cost",
    "promotion_cost",
    "other_accruals",
]


def fetch_by_month(client, view: str, cabinet: str) -> dict:
    sql = f"""
        SELECT toStartOfMonth(month) AS month, {", ".join(METRICS)}
        FROM {view}
        WHERE cabinet = {{cabinet:String}}
        ORDER BY month
    """
    rows = client.query(sql, parameters={"cabinet": cabinet}).result_rows
    return {r[0]: dict(zip(METRICS, (float(v or 0) for v in r[1:]))) for r in rows}


def run_comparison(client, cabinet: str, log=print) -> list[tuple]:
    xlsx_by_month = fetch_by_month(client, "ozon_metrics_by_cabinet_month", cabinet)
    api_by_month = fetch_by_month(client, "ozon_metrics_by_cabinet_month_cashflow_api", cabinet)
    months = sorted(set(xlsx_by_month) | set(api_by_month))

    if not months:
        log(f"Нет данных ни в одной из моделей для cabinet='{cabinet}'")
        return []

    log(f"Сверка Ozon метрик модели (новый API cash-flow vs .xlsx) для кабинета '{cabinet}': "
        f"{len(months)} месяц(ев) x {len(METRICS)} метрик\n")

    result_rows = []
    for month in months:
        x_metrics = xlsx_by_month.get(month)
        a_metrics = api_by_month.get(month)
        if x_metrics is None:
            log(f"  {month}  [НЕТ В .XLSX] — пропущено")
            continue
        if a_metrics is None:
            log(f"  {month}  [НЕТ В API] — пропущено")
            continue

        for metric in METRICS:
            x_val = x_metrics[metric]
            a_val = a_metrics[metric]
            diff = abs(x_val - a_val)
            diff_pct = (diff / abs(x_val) * 100) if x_val else None
            is_ok = 1 if diff < TOLERANCE_RUB else 0

            label = "OK" if is_ok else f"MISMATCH {diff:.2f}"
            log(f"  {month}  {metric:<20}  [{label:>18}]  xlsx={x_val:>14,.2f}  api={a_val:>14,.2f}")

            result_rows.append((
                cabinet, "ozon", month, f"cashflow_{metric}", x_val, a_val, diff, diff_pct, TOLERANCE_RUB, is_ok,
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
    parser = argparse.ArgumentParser(description="Сверка Ozon нового API (cash-flow) с .xlsx по метрикам модели")
    parser.add_argument("--cabinet", required=True, help="Название кабинета")
    args = parser.parse_args()

    client = get_client()
    run_comparison(client, args.cabinet)


if __name__ == "__main__":
    main()
