#!/usr/bin/env python3
"""
Загрузка операционной детализации Ozon через /v1/finance/accrual/postings
за диапазон месяцев в ClickHouse — CLI-обёртка над ozon_accrual_core.py.

Примеры:
    python3 ingest_ozon_accrual.py --types-only
    python3 ingest_ozon_accrual.py --cabinet CloudSix --from 2026-01 --to 2026-01
    python3 ingest_ozon_accrual.py --all-cabinets --from 2026-01 --to 2026-08
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

from ozon_accrual_core import ingest_month, ingest_accrual_types  # noqa: E402
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
    parser = argparse.ArgumentParser(description="Загрузка Ozon /v1/finance/accrual/postings в ClickHouse")
    parser.add_argument("--types-only", action="store_true", help="Только обновить справочник ozon_accrual_types и выйти")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--cabinet", help="Один кабинет, например CloudSix")
    group.add_argument("--all-cabinets", action="store_true", help="Все кабинеты с заполненным Ozon client_id")
    parser.add_argument("--from", dest="date_from", help="Первый месяц, YYYY-MM")
    parser.add_argument("--to", dest="date_to", help="Последний месяц (включительно), YYYY-MM")
    parser.add_argument("--delay", type=float, default=3.0, help="Пауза между месяцами, сек (по умолчанию 3)")
    args = parser.parse_args()

    all_cabinets = cabinets_with_ozon()

    if args.types_only:
        ingest_accrual_types(all_cabinets[0])
        return

    if not args.cabinet and not args.all_cabinets:
        print("Нужен --cabinet или --all-cabinets (или --types-only)", file=sys.stderr)
        sys.exit(1)
    if not args.date_from or not args.date_to:
        print("Нужны --from и --to", file=sys.stderr)
        sys.exit(1)

    ingest_accrual_types(all_cabinets[0])

    cabinets = [args.cabinet] if args.cabinet else all_cabinets
    months = list(month_range(args.date_from, args.date_to))
    jobs = [(c, y, m) for c in cabinets for (y, m) in months]
    print(f"\nКабинетов: {len(cabinets)}, месяцев: {len(months)}, всего заданий: {len(jobs)}, пауза: {args.delay}s\n")

    total_postings = 0
    total_rows = 0
    for i, (cabinet, year, month) in enumerate(jobs):
        if i > 0:
            time.sleep(args.delay)
        print(f"[{i + 1}/{len(jobs)}] {cabinet} {year}-{month:02d}")
        try:
            summary = ingest_month(cabinet, year, month)
        except Exception as e:
            print(f"  ОШИБКА: {e}", file=sys.stderr)
            continue
        total_postings += summary["postings"]
        total_rows += summary["accrual_rows"]

    print(f"\nВсего отправлений: {total_postings}, строк начислений: {total_rows}.")


if __name__ == "__main__":
    main()
