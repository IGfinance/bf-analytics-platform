#!/usr/bin/env python3
"""
Сверка СВОДОК отчётов WB: `wb_api_report_summary` (метод list финансового
API) против `wb_report_summary` (ручная выгрузка сводного .xlsx).

Чем отличается от compare_wb_sources.py: там сверяются ДЕТАЛЬНЫЕ строки, и
сверять их можно только агрегатами по месяцу — общего ключа у строк .xlsx и
API нет. Здесь ключ общий: `report_id` в API — это тот же идентификатор
отчёта WB, что `report_number` в .xlsx (в .xlsx он парсится из имени файла).
Поэтому сверка идёт ОТЧЁТ К ОТЧЁТУ, и расхождение сразу указывает на
конкретный отчёт, а не на месяц.

Знаки: и в сводном .xlsx, и в ответе list расходные показатели приходят
ПОЛОЖИТЕЛЬНЫМИ (в "Итого к оплате" они вычитаются — см. правило
"Итого к оплате" в reconciliation_rules_wb.yaml). Поэтому сравниваем как
есть, без инверсии.

ПАРЫ ПОЛЕЙ НИЖЕ ПРОВЕРЕНЫ НА ДАННЫХ 2026-09-27, а не сведены по смыслу
названий: взяли отчёты CloudSix 813819623 (Основной) и 813819624 (По
выкупам) за неделю 2026-08-10..16 — они уже были загружены из .xlsx — и
дёрнули на тот же период метод list. Все 8 пар × 2 отчёта = 16 сверок
совпали до копейки (напр. sale/retailAmountSum = 2 982 968.74,
total_payable/bankPaymentSum = 1 206 902.72). Тогда же подтвердилось
соответствие типов отчёта: reportType 1 = "Основной", 2 = "По выкупам".

Пример:
    python3 compare_wb_summaries.py --cabinet CloudSix
"""

import argparse
from pathlib import Path

from dotenv import load_dotenv

SCRIPT_DIR = Path(__file__).parent
load_dotenv(SCRIPT_DIR.parent / ".env")

from wb_core import get_client  # noqa: E402

# (метрика, колонка в wb_report_summary, колонка в wb_api_report_summary, допуск ₽)
# Сопоставлены только пары, в значении которых мы уверены. Показатели API,
# которым НЕ нашлось пары в сводном .xlsx, сознательно не сверяются:
#   additional_payment_sum, cashback_amount_sum, cashback_discount_sum,
#   cashback_commission_change_sum, avg_sale_percent, payment_schedule.
# Обратно, в .xlsx без пары остались: loyalty_discount_compensation,
# loyalty_program_cost, loyalty_points_deducted, wb_commission_correction,
# agreed_discount_pct, one_time_payment_term_change.
# Добавлять пару можно только подтвердив её на данных — вслепую сведённая
# пара хуже отсутствующей, она даёт ложное "OK".
METRICS = [
    ("sale_vs_retail_amount",            "sale",              "retail_amount_sum",     1.0),
    ("payable_for_goods_vs_for_pay",     "payable_for_goods", "for_pay_sum",           1.0),
    ("logistics_vs_delivery_service",    "logistics_cost",    "delivery_service_sum",  1.0),
    ("storage_vs_paid_storage",          "storage_cost",      "paid_storage_sum",      1.0),
    ("acceptance_vs_paid_acceptance",    "acceptance_cost",   "paid_acceptance_sum",   1.0),
    ("other_deductions_vs_deduction",    "other_deductions",  "deduction_sum",         1.0),
    ("total_fines_vs_penalty",           "total_fines",       "penalty_sum",           1.0),
    ("total_payable_vs_bank_payment",    "total_payable",     "bank_payment_sum",      1.0),
]


def fetch(client, cabinet: str) -> tuple[dict, dict]:
    xlsx_cols = ", ".join(f"{c} AS m{i}" for i, (_, c, _, _) in enumerate(METRICS))
    api_cols = ", ".join(f"{c} AS m{i}" for i, (_, _, c, _) in enumerate(METRICS))

    xlsx = client.query(
        f"SELECT report_number, {xlsx_cols} FROM wb_report_summary FINAL "
        "WHERE cabinet = {cabinet:String}",
        parameters={"cabinet": cabinet},
    ).result_rows
    api = client.query(
        f"SELECT report_id, {api_cols} FROM wb_api_report_summary FINAL "
        "WHERE cabinet = {cabinet:String}",
        parameters={"cabinet": cabinet},
    ).result_rows
    return {r[0]: r[1:] for r in xlsx}, {r[0]: r[1:] for r in api}


def run_comparison(client, cabinet: str, log=print) -> list[tuple]:
    xlsx_by_report, api_by_report = fetch(client, cabinet)
    reports = sorted(set(xlsx_by_report) | set(api_by_report))

    if not reports:
        log(f"Нет данных ни в wb_report_summary, ни в wb_api_report_summary для cabinet='{cabinet}'")
        return []

    only_xlsx = sorted(set(xlsx_by_report) - set(api_by_report))
    only_api = sorted(set(api_by_report) - set(xlsx_by_report))
    log(f"Сверка сводок WB API vs .xlsx, кабинет '{cabinet}': "
        f"{len(reports)} отчёт(ов), общих {len(set(xlsx_by_report) & set(api_by_report))}")
    if only_xlsx:
        log(f"  только в .xlsx ({len(only_xlsx)}): {only_xlsx[:10]}{' ...' if len(only_xlsx) > 10 else ''}")
    if only_api:
        log(f"  только в API ({len(only_api)}): {only_api[:10]}{' ...' if len(only_api) > 10 else ''}")
    log("")

    result_rows = []
    for report_id in reports:
        xlsx_vals = xlsx_by_report.get(report_id)
        api_vals = api_by_report.get(report_id)
        # Отчёт, которого нет с одной из сторон, не сверяем: сравнение с
        # нулём дало бы MISMATCH на всю сумму и утопило бы реальные
        # расхождения (ровно так 76 из 102 проверок "расходились" в
        # compare_wb_sources.py, пока wb_api_realization была пуста).
        if xlsx_vals is None or api_vals is None:
            continue

        log(f"  отчёт {report_id}:")
        for i, (metric, _, _, tolerance) in enumerate(METRICS):
            x_val = float(xlsx_vals[i]) if xlsx_vals[i] is not None else 0.0
            a_val = float(api_vals[i]) if api_vals[i] is not None else 0.0
            diff = abs(x_val - a_val)
            diff_pct = (diff / abs(x_val) * 100) if x_val else None
            is_ok = 1 if diff < tolerance else 0
            label = "OK" if is_ok else f"MISMATCH {diff:.2f}"
            log(f"      [{label:>18}] {metric:<38} xlsx={x_val:>14,.2f}  api={a_val:>14,.2f}")
            result_rows.append((
                cabinet, report_id, metric,
                x_val, a_val, diff, diff_pct, tolerance, is_ok,
            ))

    if not result_rows:
        log("\nОбщих отчётов нет — сверять нечего (загрузите обе стороны за один период).")
        return []

    client.insert(
        "wb_api_summary_reconciliation",
        result_rows,
        column_names=["cabinet", "report_id", "metric", "xlsx_value", "api_value",
                      "diff", "diff_pct", "tolerance", "is_ok"],
    )

    ok_count = sum(r[-1] for r in result_rows)
    log(f"\nИтого: {len(result_rows)} проверок, совпало: {ok_count}, "
        f"разошлось: {len(result_rows) - ok_count}")
    return result_rows


def main():
    parser = argparse.ArgumentParser(description="Сверка сводок WB: API (list) vs ручной .xlsx")
    parser.add_argument("--cabinet", required=True, help="Название кабинета")
    args = parser.parse_args()
    run_comparison(get_client(), args.cabinet)


if __name__ == "__main__":
    main()
