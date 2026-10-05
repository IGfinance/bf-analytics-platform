#!/usr/bin/env python3
"""
Загрузка вкладки «Продв Ozon» (Google-Таблица «Продвижение CS») в ClickHouse —
CLI-обёртка над promotion_gsheets_core.ingest_ozon_promotion.

Пример:
    python3 ingest_ozon_promotion.py --project-id 1
    python3 ingest_ozon_promotion.py --project-id 1 --dry-run
"""

import argparse
import os
import sys

from dotenv_safe import load_dotenv

from promotion_gsheets_core import (
    SCRIPT_DIR, OZON_PROMOTION_SHEET_NAME, read_tab, parse_ozon_promotion, ingest_ozon_promotion,
)

load_dotenv(SCRIPT_DIR.parent / ".env")


def main():
    parser = argparse.ArgumentParser(description="Загрузка «Продв Ozon» из Google-Таблицы в ClickHouse")
    parser.add_argument("--project-id", required=True, type=int, help="ID проекта (CloudSix = 1)")
    parser.add_argument("--spreadsheet-id", help="ID таблицы (по умолчанию из GSHEETS_SPREADSHEET_ID_CLOUDSIX_PROMOTION)")
    parser.add_argument("--dry-run", action="store_true", help="Не писать в ClickHouse, только проверить")
    args = parser.parse_args()

    spreadsheet_id = args.spreadsheet_id or os.environ.get("GSHEETS_SPREADSHEET_ID_CLOUDSIX_PROMOTION")
    if not spreadsheet_id:
        print("Ошибка: не задан GSHEETS_SPREADSHEET_ID_CLOUDSIX_PROMOTION (или --spreadsheet-id)", file=sys.stderr)
        sys.exit(1)

    if args.dry_run:
        values = read_tab(spreadsheet_id, OZON_PROMOTION_SHEET_NAME)
        rows, skipped = parse_ozon_promotion(values)
        print(f"Строк «Продв Ozon»: {len(rows)}, пропущено: {skipped}")
        print("Dry-run: в ClickHouse ничего не пишу.")
        return

    try:
        summary = ingest_ozon_promotion(args.project_id, spreadsheet_id=spreadsheet_id)
    except ValueError as e:
        print(f"Ошибка: {e}", file=sys.stderr)
        sys.exit(1)
    print(f"Загружено строк: {summary['rows']}, пропущено: {summary['skipped']}")


if __name__ == "__main__":
    main()
