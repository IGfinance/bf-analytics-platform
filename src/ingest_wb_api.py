#!/usr/bin/env python3
"""
Загрузка отчётов о реализации WB за период через финансовое API — CLI-обёртка
над wb_api_core.py.

Грузит две вещи: сводку по каждому отчёту периода (метод list →
wb_api_report_summary) и строки детализации (detailed/{reportId} →
wb_api_realization). Флаг --summary-only останавливается на первом —
это ОДИН запрос к API, и с него стоит начинать знакомство с новым периодом:
видно, сколько отчётов и какие в них суммы, прежде чем запускать долгую
выкачку строк.

ЛИМИТ 1 запрос в минуту — загрузка большого периода идёт часами, пауза между
запросами держится автоматически. Оценка: один отчёт = 1 запрос на каждые
10 000 строк, недельный отчёт CloudSix — около 6000 строк, то есть пара
запросов; плюс один запрос на сам list.

Примеры:
    python3 ingest_wb_api.py --cabinet CloudSix --date-from 2026-08-17 --date-to 2026-08-23 --summary-only
    python3 ingest_wb_api.py --cabinet CloudSix --date-from 2026-08-17 --date-to 2026-08-23
"""

import argparse
import sys
from datetime import date
from pathlib import Path

from dotenv_safe import load_dotenv

SCRIPT_DIR = Path(__file__).parent
load_dotenv(SCRIPT_DIR.parent / ".env")

from wb_api_core import ingest_period  # noqa: E402 (нужен load_dotenv до импорта)


def main():
    parser = argparse.ArgumentParser(
        description="Загрузка отчётов о реализации WB через финансовое API в ClickHouse")
    parser.add_argument("--cabinet", required=True, help="Название кабинета, например CloudSix")
    parser.add_argument("--date-from", required=True, help="Начало периода, YYYY-MM-DD")
    parser.add_argument("--date-to", required=True, help="Конец периода, YYYY-MM-DD")
    parser.add_argument("--summary-only", action="store_true",
                        help="только перечень отчётов и их суммы (1 запрос), без строк детализации")
    parser.add_argument("--database", help="БД проекта в ClickHouse (по умолчанию CLICKHOUSE_DATABASE)")
    args = parser.parse_args()

    date_from = date.fromisoformat(args.date_from)
    date_to = date.fromisoformat(args.date_to)
    if date_from > date_to:
        print("Ошибка: date-from позже date-to", file=sys.stderr)
        sys.exit(1)

    summary = ingest_period(
        args.cabinet, date_from, date_to,
        database=args.database, with_detailed=not args.summary_only,
    )
    print(f"\nОтчётов: {summary['reports']}, "
          f"строк сводки: {summary['summary_rows']}, "
          f"строк детализации: {summary['detailed_rows']}")


if __name__ == "__main__":
    main()
