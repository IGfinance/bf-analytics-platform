#!/usr/bin/env python3
"""
Сверка "WB API (wb_api_realization)" с "ручная выгрузка .xlsx (wb_reports)"
по кабинету — проверяет, что автоматическая загрузка через API даёт те же
суммы, что и отчёты, которые продавец сейчас скачивает вручную.

Группировка — по месяцу: на стороне .xlsx по coalesce(order_date, sale_date)
(так же, как партиционируется wb_reports), на стороне API — по rr_dt
(дата строки отчёта о реализации). Построчного сопоставления нет — у API
есть свой rrd_id, но в .xlsx такого столбца нет.

Пример:
    python3 compare_wb_sources.py --cabinet CloudSix
"""

import argparse
from pathlib import Path

from dotenv import load_dotenv

SCRIPT_DIR = Path(__file__).parent
load_dotenv(SCRIPT_DIR.parent / ".env")

from wb_core import get_client  # noqa: E402

# (метрика, xlsx-выражение, api-выражение, допуск в рублях/штуках)
METRICS = [
    ("payable_to_seller_vs_ppvz_for_pay",
     "sum(payable_to_seller)", "sum(ppvz_for_pay)", 100.0),
    ("wb_realized_amount_vs_retail_amount",
     "sum(wb_realized_amount)", "sum(retail_amount)", 100.0),
    ("qty_vs_quantity",
     "sum(qty)", "sum(quantity)", 1.0),
    ("delivery_service_cost_vs_delivery_rub",
     "sum(delivery_service_cost)", "sum(delivery_rub)", 50.0),
    ("total_fines_vs_penalty",
     "sum(total_fines)", "sum(penalty)", 10.0),
    ("storage_cost_vs_storage_fee",
     "sum(storage_cost)", "sum(storage_fee)", 10.0),
]


def fetch_xlsx_by_month(client, cabinet: str) -> dict:
    exprs = ", ".join(f"{expr} AS m{i}" for i, (_, expr, _, _) in enumerate(METRICS))
    sql = f"""
        SELECT toStartOfMonth(coalesce(order_date, sale_date)) AS month, {exprs}
        FROM wb_reports FINAL
        WHERE cabinet = {{cabinet:String}}
        GROUP BY month
        ORDER BY month
    """
    rows = client.query(sql, parameters={"cabinet": cabinet}).result_rows
    return {r[0]: r[1:] for r in rows}


def fetch_api_by_month(client, cabinet: str) -> dict:
    exprs = ", ".join(f"{expr} AS m{i}" for i, (_, _, expr, _) in enumerate(METRICS))
    sql = f"""
        SELECT toStartOfMonth(rr_dt) AS month, {exprs}
        FROM wb_api_realization FINAL
        WHERE cabinet = {{cabinet:String}}
        GROUP BY month
        ORDER BY month
    """
    rows = client.query(sql, parameters={"cabinet": cabinet}).result_rows
    return {r[0]: r[1:] for r in rows}


def run_comparison(client, cabinet: str, log=print) -> list[tuple]:
    xlsx_by_month = fetch_xlsx_by_month(client, cabinet)
    api_by_month = fetch_api_by_month(client, cabinet)
    months = sorted(set(xlsx_by_month) | set(api_by_month))

    if not months:
        log(f"Нет данных ни в wb_reports, ни в wb_api_realization для cabinet='{cabinet}'")
        return []

    log(f"Сверка WB API vs .xlsx для кабинета '{cabinet}': {len(months)} месяц(ев)\n")

    result_rows = []
    for month in months:
        xlsx_vals = xlsx_by_month.get(month)
        api_vals = api_by_month.get(month)
        log(f"  {month}:" + ("  [НЕТ В API]" if api_vals is None else "") + ("  [НЕТ В .XLSX]" if xlsx_vals is None else ""))

        for i, (metric, _, _, tolerance) in enumerate(METRICS):
            x_val = float(xlsx_vals[i]) if xlsx_vals and xlsx_vals[i] is not None else 0.0
            a_val = float(api_vals[i]) if api_vals and api_vals[i] is not None else 0.0
            diff = abs(x_val - a_val)
            diff_pct = (diff / abs(x_val) * 100) if x_val else None
            is_ok = 1 if diff <= tolerance else 0

            label = "OK" if is_ok else f"MISMATCH {diff:.2f}"
            log(f"      [{label:>18}] {metric:<40} xlsx={x_val:>14,.2f}  api={a_val:>14,.2f}")

            result_rows.append((
                cabinet, "wb", month, metric, x_val, a_val, diff, diff_pct, tolerance, is_ok,
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
    parser = argparse.ArgumentParser(description="Сверка WB API с ручной выгрузкой .xlsx")
    parser.add_argument("--cabinet", required=True, help="Название кабинета")
    args = parser.parse_args()

    client = get_client()
    run_comparison(client, args.cabinet)


if __name__ == "__main__":
    main()
