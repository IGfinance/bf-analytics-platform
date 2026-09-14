#!/usr/bin/env python3
"""
Загрузка ФОТ Реальта (вкладка «Импорт ФОТ» Google-Таблицы) в ClickHouse —
CLI-обёртка над realt_gsheets_core.ingest_payroll. Данные тянутся напрямую
через Google Sheets API (сервис-аккаунт), файл выгружать не нужно.

Пример:
    python3 ingest_realt_payroll.py --project-id 2
    python3 ingest_realt_payroll.py --project-id 2 --dry-run
"""

import argparse
import os
import sys

from dotenv import load_dotenv

from realt_gsheets_core import (
    SCRIPT_DIR, PAYROLL_SHEET_NAME, read_tab, parse_payroll, ingest_payroll,
)

load_dotenv(SCRIPT_DIR.parent / ".env")  # .env лежит в корне репозитория, на уровень выше src/


def main():
    parser = argparse.ArgumentParser(description="Загрузка ФОТ Реальта из Google-Таблицы в ClickHouse")
    parser.add_argument("--project-id", required=True, type=int, help="ID проекта (Реальт)")
    parser.add_argument("--spreadsheet-id", help="ID таблицы (по умолчанию из GSHEETS_SPREADSHEET_ID)")
    parser.add_argument("--dry-run", action="store_true", help="Не писать в ClickHouse, только проверить")
    args = parser.parse_args()

    spreadsheet_id = args.spreadsheet_id or os.environ.get("GSHEETS_SPREADSHEET_ID")
    if not spreadsheet_id:
        print("Ошибка: не задан GSHEETS_SPREADSHEET_ID (или --spreadsheet-id)", file=sys.stderr)
        sys.exit(1)

    if args.dry_run:
        values = read_tab(spreadsheet_id, PAYROLL_SHEET_NAME)
        rows, skipped = parse_payroll(values)
        print(f"Строк ФОТ: {len(rows)}, пропущено: {skipped}")
        print("Dry-run: в ClickHouse ничего не пишу.")
        return

    try:
        summary = ingest_payroll(args.project_id, spreadsheet_id=spreadsheet_id)
    except ValueError as e:
        print(f"Ошибка: {e}", file=sys.stderr)
        sys.exit(1)
    print(f"Загружено строк: {summary['rows']}, пропущено: {summary['skipped']}")


if __name__ == "__main__":
    main()
