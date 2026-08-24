#!/usr/bin/env python3
"""
Проверки качества данных в wb_reports. Находит типичные проблемы в отчётах WB:
дубли операций между разными отчётами, пропуски дат, некорректные значения,
пропущенные недели, новые непромаппленные колонки.

Результат каждого запуска пишется в wb_check_results (история проверок).

Пример:
    python3 check_wb.py --cabinet AcmeShop
    python3 check_wb.py --cabinet AcmeShop --verbose   # показать примеры проблемных строк
"""

import argparse
from dotenv import load_dotenv

from wb_core import get_client, SCRIPT_DIR

load_dotenv(SCRIPT_DIR / ".env")

CHECK_RESULTS_TABLE_DDL = """
CREATE TABLE IF NOT EXISTS wb_check_results
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
    "duplicate_operations_across_reports": {
        "description": "Одна и та же операция (Srid) встречается в разных отчётах — обычно это стык соседних "
                        "еженедельных отчётов (норма), но при суммировании по всем report_number сразу "
                        "приведёт к задвоению — фильтруйте по одному report_number или дедуплицируйте по srid",
        "sql": """
            SELECT srid, groupArray(DISTINCT report_number) AS reports, count() AS n
            FROM wb_reports FINAL
            WHERE cabinet = {cabinet:String} AND srid != '' AND document_type IN ('Продажа', 'Возврат')
            GROUP BY srid
            HAVING uniqExact(report_number) > 1
            ORDER BY n DESC
        """,
    },
    "negative_qty_on_sale": {
        "description": "Отрицательное количество в строке с типом документа 'Продажа'",
        "sql": """
            SELECT cabinet, report_number, row_num, srid, qty, source_file
            FROM wb_reports FINAL
            WHERE cabinet = {cabinet:String} AND document_type = 'Продажа' AND qty < 0
        """,
    },
    "missing_product_identity": {
        "description": "У продажи/возврата пустой баркод или название товара (не считая ПВЗ-компенсаций — там это норма)",
        "sql": """
            SELECT cabinet, report_number, row_num, srid, barcode, product_name, source_file
            FROM wb_reports FINAL
            WHERE cabinet = {cabinet:String}
              AND document_type IN ('Продажа', 'Возврат')
              AND payment_reason NOT IN ('Возмещение за выдачу и возврат товаров на ПВЗ')
              AND (barcode IS NULL OR barcode = '' OR product_name IS NULL OR product_name = '')
        """,
    },
    "future_dates": {
        "description": "Дата продажи или заказа в будущем — похоже на ошибку выгрузки",
        "sql": """
            SELECT cabinet, report_number, row_num, srid, order_date, sale_date, source_file
            FROM wb_reports FINAL
            WHERE cabinet = {cabinet:String}
              AND (sale_date > today() OR order_date > today())
        """,
    },
    "weeks_without_data": {
        "description": "Недели внутри диапазона загруженных данных, за которые нет ни одной строки (пропущенный отчёт)",
        "sql": """
            WITH bounds AS (
                SELECT min(sale_date) AS min_d, max(sale_date) AS max_d
                FROM wb_reports FINAL
                WHERE cabinet = {cabinet:String} AND sale_date IS NOT NULL
            ),
            all_weeks AS (
                SELECT toStartOfWeek(min_d) + INTERVAL number WEEK AS week_start
                FROM bounds
                ARRAY JOIN range(0, toUInt32(dateDiff('week', min_d, max_d)) + 1) AS number
            ),
            present_weeks AS (
                SELECT DISTINCT toStartOfWeek(sale_date) AS week_start
                FROM wb_reports FINAL
                WHERE cabinet = {cabinet:String} AND sale_date IS NOT NULL
            )
            SELECT week_start
            FROM all_weeks
            WHERE week_start NOT IN (SELECT week_start FROM present_weeks)
            ORDER BY week_start
        """,
    },
    "unmapped_columns_recent": {
        "description": "Новые колонки, которых нет в column_mapping_wb.yaml (нужно обновить маппинг)",
        "sql": """
            SELECT raw_column_name, count() AS n, max(seen_at) AS last_seen
            FROM wb_unmapped_columns_log
            GROUP BY raw_column_name
            ORDER BY last_seen DESC
        """,
        "no_cabinet_filter": True,
    },
}


def run_checks(client, cabinet: str, verbose: bool = False):
    client.command(CHECK_RESULTS_TABLE_DDL)

    print(f"Проверка данных WB для кабинета: {cabinet}\n")
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
        "wb_check_results",
        results,
        column_names=["cabinet", "check_name", "anomalies", "details"],
    )


def main():
    parser = argparse.ArgumentParser(description="Проверки качества данных WB в ClickHouse")
    parser.add_argument("--cabinet", required=True)
    parser.add_argument("--verbose", action="store_true", help="Показать примеры проблемных строк")
    args = parser.parse_args()

    client = get_client()
    run_checks(client, args.cabinet, verbose=args.verbose)


if __name__ == "__main__":
    main()
