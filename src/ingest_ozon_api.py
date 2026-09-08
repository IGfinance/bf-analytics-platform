#!/usr/bin/env python3
"""
Загрузка финансовых операций Ozon за период через Seller API — CLI-обёртка
над ozon_api_core.py.

Период разбивается на помесячные куски (Ozon отдаёт только уже проведённые
начисления, но за долгий период это десятки тысяч строк — помесячная
загрузка даёт прогресс и позволяет перезапустить с середины).

Пример:
    python3 ingest_ozon_api.py --cabinet CloudSix --date-from 2026-01-01 --date-to 2026-09-08
"""

import argparse
import sys
from datetime import date, timedelta
from pathlib import Path

from dotenv import load_dotenv

SCRIPT_DIR = Path(__file__).parent
load_dotenv(SCRIPT_DIR.parent / ".env")

from ozon_api_core import ingest_period  # noqa: E402 (нужен load_dotenv до импорта)


def month_chunks(date_from: date, date_to: date):
    cur = date_from.replace(day=1)
    while cur <= date_to:
        if cur.month == 12:
            next_month = cur.replace(year=cur.year + 1, month=1, day=1)
        else:
            next_month = cur.replace(month=cur.month + 1, day=1)
        chunk_end = min(next_month - timedelta(days=1), date_to)
        chunk_start = max(cur, date_from)
        yield chunk_start, chunk_end
        cur = next_month


def main():
    parser = argparse.ArgumentParser(description="Загрузка финансовых операций Ozon через API в ClickHouse")
    parser.add_argument("--cabinet", required=True, help="Название кабинета, например CloudSix")
    parser.add_argument("--date-from", required=True, help="Начало периода, YYYY-MM-DD")
    parser.add_argument("--date-to", required=True, help="Конец периода, YYYY-MM-DD")
    args = parser.parse_args()

    date_from = date.fromisoformat(args.date_from)
    date_to = date.fromisoformat(args.date_to)
    if date_from > date_to:
        print("Ошибка: date-from позже date-to", file=sys.stderr)
        sys.exit(1)

    total_rows = 0
    for chunk_start, chunk_end in month_chunks(date_from, date_to):
        print(f"Период {chunk_start} — {chunk_end}:")
        summary = ingest_period(args.cabinet, chunk_start, chunk_end)
        total_rows += summary["rows"]

    print(f"\nВсего загружено строк: {total_rows}")


if __name__ == "__main__":
    main()
