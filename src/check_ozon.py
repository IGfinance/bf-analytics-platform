#!/usr/bin/env python3
"""
Проверки качества данных в ozon_reports. Аналог check_wb.py, адаптирован под
структуру Ozon: нет report_number (используем source_file), нет document_type
(используем service_group), дедуп-ключ ID начисления неуникален построчно.

Результат каждого запуска пишется в ozon_check_results (история проверок).

Пример:
    python3 check_ozon.py --cabinet Torado
    python3 check_ozon.py --cabinet Torado --verbose   # показать примеры проблемных строк
"""

import argparse
from dotenv import load_dotenv

from ozon_core import get_client, SCRIPT_DIR

load_dotenv(SCRIPT_DIR.parent / ".env")  # .env лежит в корне репозитория, на уровень выше src/

CHECK_RESULTS_TABLE_DDL = """
CREATE TABLE IF NOT EXISTS ozon_check_results
(
    run_at      DateTime DEFAULT now(),
    cabinet     String,
    check_name  String,
    anomalies   UInt64,
    details     String
)
ENGINE = MergeTree
ORDER BY (run_at, check_name)
"""

# Каждая проверка — SQL, возвращающий строки-аномалии.
# {cabinet} подставляется параметром. FINAL — чтобы не путаться с ещё не
# смёрженными дублями ReplacingMergeTree.
CHECKS = {
    "duplicate_operations_across_files": {
        "description": "Одна и та же операция (ID начисления + тип + сумма) встречается в нескольких разных "
                        "исходных файлах — похоже на перекрывающиеся выгрузки за один и тот же период, "
                        "при суммировании по всем файлам сразу приведёт к задвоению",
        "sql": """
            SELECT accrual_id, service_group, accrual_type, sku, total_amount,
                   groupArray(DISTINCT source_file) AS files, count() AS n
            FROM ozon_reports FINAL
            WHERE cabinet = {cabinet:String} AND accrual_id IS NOT NULL AND accrual_id != ''
            GROUP BY accrual_id, service_group, accrual_type, sku, total_amount
            HAVING uniqExact(source_file) > 1
            ORDER BY n DESC
        """,
    },
    "negative_qty_on_sale": {
        "description": "Отрицательное количество в строке с группой услуг 'Продажи'",
        "sql": """
            SELECT cabinet, source_file, row_num, accrual_id, qty
            FROM ozon_reports FINAL
            WHERE cabinet = {cabinet:String} AND service_group = 'Продажи' AND qty < 0
        """,
    },
    "missing_product_identity": {
        "description": "У продажи/возврата пустой артикул или название товара",
        "sql": """
            SELECT cabinet, source_file, row_num, accrual_id, article, product_name
            FROM ozon_reports FINAL
            WHERE cabinet = {cabinet:String}
              AND service_group IN ('Продажи', 'Возвраты')
              AND (article IS NULL OR article = '' OR product_name IS NULL OR product_name = '')
        """,
    },
    "future_dates": {
        "description": "Дата начисления или дата принятия заказа в будущем — похоже на ошибку выгрузки",
        "sql": """
            SELECT cabinet, source_file, row_num, accrual_id, accrual_date, order_accepted_date
            FROM ozon_reports FINAL
            WHERE cabinet = {cabinet:String}
              AND (accrual_date > today() OR order_accepted_date > today())
        """,
    },
    "weeks_without_data": {
        "description": "Недели внутри диапазона загруженных данных, за которые нет ни одной строки",
        "sql": """
            WITH bounds AS (
                SELECT min(accrual_date) AS min_d, max(accrual_date) AS max_d
                FROM ozon_reports FINAL
                WHERE cabinet = {cabinet:String} AND accrual_date IS NOT NULL
            ),
            all_weeks AS (
                SELECT toStartOfWeek(min_d) + INTERVAL number WEEK AS week_start
                FROM bounds
                ARRAY JOIN range(0, toUInt32(dateDiff('week', min_d, max_d)) + 1) AS number
            ),
            present_weeks AS (
                SELECT DISTINCT toStartOfWeek(accrual_date) AS week_start
                FROM ozon_reports FINAL
                WHERE cabinet = {cabinet:String} AND accrual_date IS NOT NULL
            )
            SELECT week_start
            FROM all_weeks
            WHERE week_start NOT IN (SELECT week_start FROM present_weeks)
            ORDER BY week_start
        """,
    },
    "unmapped_columns_recent": {
        "description": "Новые колонки, которых нет в column_mapping_ozon.yaml (нужно обновить маппинг)",
        "sql": """
            SELECT raw_column_name, count() AS n, max(seen_at) AS last_seen
            FROM ozon_unmapped_columns_log
            GROUP BY raw_column_name
            ORDER BY last_seen DESC
        """,
        "no_cabinet_filter": True,
    },
}


def run_checks(client, cabinet: str, verbose: bool = False):
    client.command(CHECK_RESULTS_TABLE_DDL)

    print(f"Проверка данных Ozon для кабинета: {cabinet}\n")
    results = []
    for name, check in CHECKS.items():
        params = {} if check.get("no_cabinet_filter") else {"cabinet": cabinet}
        # без LIMIT — чтобы узнать точное число аномалий, а не то, что попало в LIMIT детального запроса
        count_sql = f"SELECT count() FROM ({check['sql']})"
        n = client.query(count_sql, parameters=params).result_rows[0][0]

        status = "OK" if n == 0 else f"АНОМАЛИИ: {n}"
        print(f"[{status:14}] {name} — {check['description']}")

        sample_rows = []
        if n > 0:
            res = client.query(check["sql"], parameters=params)
            sample_rows = res.result_rows[:10]
            if verbose:
                for row in sample_rows:
                    print("    ", dict(zip(res.column_names, row)))
                if n > len(sample_rows):
                    print(f"    ... и ещё {n - len(sample_rows)}")
        print()

        details = "; ".join(str(row) for row in sample_rows)
        results.append((cabinet, name, n, details))

    client.insert(
        "ozon_check_results",
        results,
        column_names=["cabinet", "check_name", "anomalies", "details"],
    )


def main():
    parser = argparse.ArgumentParser(description="Проверки качества данных Ozon в ClickHouse")
    parser.add_argument("--cabinet", required=True)
    parser.add_argument("--verbose", action="store_true", help="Показать примеры проблемных строк")
    args = parser.parse_args()

    client = get_client()
    run_checks(client, args.cabinet, verbose=args.verbose)


if __name__ == "__main__":
    main()
