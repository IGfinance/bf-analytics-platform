#!/usr/bin/env python3
"""
Загрузка отчёта о реализации WB за период через Statistics API — CLI-обёртка
над wb_api_core.py.

Один запрос покрывает весь диапазон dateFrom/dateTo (пагинация — курсором
rrdid, не по датам), но метод жёстко лимитирован по частоте запросов —
загрузка большого периода может занять время из-за пауз на 429.

Пример:
    python3 ingest_wb_api.py --cabinet CloudSix --date-from 2025-09-21 --date-to 2026-09-08
"""

import argparse
import sys
from datetime import date
from pathlib import Path

from dotenv import load_dotenv

SCRIPT_DIR = Path(__file__).parent
load_dotenv(SCRIPT_DIR.parent / ".env")

from wb_api_core import ingest_period  # noqa: E402 (нужен load_dotenv до импорта)


def main():
    parser = argparse.ArgumentParser(description="Загрузка отчёта о реализации WB через API в ClickHouse")
    parser.add_argument("--cabinet", required=True, help="Название кабинета, например CloudSix")
    parser.add_argument("--date-from", required=True, help="Начало периода, YYYY-MM-DD")
    parser.add_argument("--date-to", required=True, help="Конец периода, YYYY-MM-DD")
    args = parser.parse_args()

    date_from = date.fromisoformat(args.date_from)
    date_to = date.fromisoformat(args.date_to)
    if date_from > date_to:
        print("Ошибка: date-from позже date-to", file=sys.stderr)
        sys.exit(1)

    summary = ingest_period(args.cabinet, date_from, date_to)
    print(f"\nВсего загружено строк: {summary['rows']}")


if __name__ == "__main__":
    main()
