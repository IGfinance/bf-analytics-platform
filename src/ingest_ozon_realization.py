#!/usr/bin/env python3
"""
Загрузка отчёта Ozon "Продажи и возвраты" (/v2/finance/realization) за
диапазон месяцев в ClickHouse — CLI-обёртка над ozon_realization_core.py.

Между месяцами и между кабинетами — пауза (--delay), см. переписку
2026-09-20 про блокировку ключей при частых запросах.

Примеры:
    python3 ingest_ozon_realization.py --cabinet CloudSix --from 2026-01 --to 2026-08
    python3 ingest_ozon_realization.py --all-cabinets --from 2026-01 --to 2026-08
"""

import argparse
import json
import sys
import time
from pathlib import Path

from dotenv import load_dotenv

SCRIPT_DIR = Path(__file__).parent
REPO_ROOT = SCRIPT_DIR.parent
load_dotenv(REPO_ROOT / ".env")

from ozon_realization_core import ingest_month  # noqa: E402
from cabinet_credentials import _keys_path  # noqa: E402


def month_range(start: str, end: str):
    sy, sm = (int(x) for x in start.split("-"))
    ey, em = (int(x) for x in end.split("-"))
    y, m = sy, sm
    while (y, m) <= (ey, em):
        yield y, m
        m += 1
        if m > 12:
            m = 1
            y += 1


def cabinets_with_ozon() -> list[str]:
    with open(_keys_path(), encoding="utf-8") as f:
        data = json.load(f)
    return sorted(name for name, v in data.items() if v.get("ozon", {}).get("client_id"))


def main():
    parser = argparse.ArgumentParser(description="Загрузка Ozon /v2/finance/realization в ClickHouse")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--cabinet", help="Один кабинет, например CloudSix")
    group.add_argument("--all-cabinets", action="store_true", help="Все кабинеты с заполненным Ozon client_id")
    parser.add_argument("--from", dest="date_from", required=True, help="Первый месяц, YYYY-MM")
    parser.add_argument("--to", dest="date_to", required=True, help="Последний месяц (включительно), YYYY-MM")
    parser.add_argument("--delay", type=float, default=15.0, help="Пауза между запросами, сек (по умолчанию 15)")
    args = parser.parse_args()

    cabinets = [args.cabinet] if args.cabinet else cabinets_with_ozon()
    months = list(month_range(args.date_from, args.date_to))

    jobs = [(c, y, m) for c in cabinets for (y, m) in months]
    print(f"Кабинетов: {len(cabinets)}, месяцев: {len(months)}, всего запросов: {len(jobs)}, пауза: {args.delay}s\n")

    total_rows = 0
    found_count = 0
    for i, (cabinet, year, month) in enumerate(jobs):
        if i > 0:
            time.sleep(args.delay)
        print(f"[{i + 1}/{len(jobs)}] {cabinet} {year}-{month:02d}")
        try:
            summary = ingest_month(cabinet, year, month)
        except Exception as e:
            print(f"  ОШИБКА: {e}", file=sys.stderr)
            continue
        total_rows += summary["rows"]
        found_count += 1 if summary["found"] else 0

    print(f"\nВсего загружено строк: {total_rows}. Месяцев с отчётом: {found_count}/{len(jobs)}.")


if __name__ == "__main__":
    main()
