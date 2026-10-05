#!/usr/bin/env python3
"""
Загрузка всех вкладок Google-Таблицы «Продвижение CS» (Продв WB, Продв Ozon,
Справочник WB/Ozon) в ClickHouse за один запуск — для cron. Каждая загрузка —
полный снимок вкладки; *_current-вьюхи берут последний (см. schema_promotion.sql).
Код возврата 1, если хоть одна вкладка упала.

Пример:
    python3 ingest_promotion.py --project-id 1 --database cloudsix
    python3 ingest_promotion.py --project-id 1 --dry-run
"""

import argparse
import os
import sys

from dotenv_safe import load_dotenv

from promotion_gsheets_core import (
    SCRIPT_DIR, REFERENCE_SHEET_NAME, OZON_PROMOTION_SHEET_NAME, WB_PROMOTION_SHEET_NAME,
    read_tab, parse_wb_promotion, parse_ozon_promotion,
    parse_wb_promotion_reference, parse_ozon_promotion_reference, ingest_all,
)

load_dotenv(SCRIPT_DIR.parent / ".env")


def main():
    parser = argparse.ArgumentParser(description="Загрузка «Продвижение CS» (все вкладки) в ClickHouse")
    parser.add_argument("--project-id", required=True, type=int, help="ID проекта (CloudSix = 1)")
    parser.add_argument("--database", help="БД ClickHouse (по умолчанию CLICKHOUSE_DATABASE)")
    parser.add_argument("--spreadsheet-id", help="ID таблицы (по умолчанию GSHEETS_SPREADSHEET_ID_CLOUDSIX_PROMOTION)")
    parser.add_argument("--dry-run", action="store_true", help="Не писать в ClickHouse, только разобрать вкладки")
    args = parser.parse_args()

    spreadsheet_id = args.spreadsheet_id or os.environ.get("GSHEETS_SPREADSHEET_ID_CLOUDSIX_PROMOTION")
    if not spreadsheet_id:
        print("Ошибка: не задан GSHEETS_SPREADSHEET_ID_CLOUDSIX_PROMOTION (или --spreadsheet-id)", file=sys.stderr)
        sys.exit(1)

    if args.dry_run:
        for name, parse_fn, tab in [
            ("Продв WB", parse_wb_promotion, WB_PROMOTION_SHEET_NAME),
            ("Продв Ozon", parse_ozon_promotion, OZON_PROMOTION_SHEET_NAME),
            ("Справочник WB", parse_wb_promotion_reference, REFERENCE_SHEET_NAME),
            ("Справочник Ozon", parse_ozon_promotion_reference, REFERENCE_SHEET_NAME),
        ]:
            rows, skipped = parse_fn(read_tab(spreadsheet_id, tab))
            print(f"{name}: строк {len(rows)}, пропущено {skipped}")
        print("Dry-run: в ClickHouse ничего не пишу.")
        return

    results = ingest_all(args.project_id, database=args.database, spreadsheet_id=spreadsheet_id)
    failed = [n for n, r in results.items() if "error" in r]
    for name, r in results.items():
        print(f"{name}: {r}")
    if failed:
        print(f"Упали вкладки: {', '.join(failed)}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
