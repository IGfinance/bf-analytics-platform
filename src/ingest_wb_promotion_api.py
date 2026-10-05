#!/usr/bin/env python3
"""
Загрузка расходов на продвижение WB из рекламного API (/adv/v1/upd) в
wb_promotion_api — CLI-обёртка над wb_promotion_api_core. Периоды длиннее
31 дня режутся на окна сами.

Примеры:
    python3 ingest_wb_promotion_api.py --cabinet CloudSix --date-from 2026-08-01 --date-to 2026-08-31 --dry-run
    python3 ingest_wb_promotion_api.py --all-cabinets --date-from 2026-09-28 --date-to 2026-10-05
"""

import argparse
import sys
from datetime import date
from pathlib import Path

from dotenv_safe import load_dotenv

SCRIPT_DIR = Path(__file__).parent
load_dotenv(SCRIPT_DIR.parent / ".env")

from cabinet_credentials import list_wb_cabinets  # noqa: E402
from wb_promotion_api_core import ingest_period  # noqa: E402


def main():
    p = argparse.ArgumentParser(description="Загрузка продвижения WB из рекламного API в ClickHouse")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--cabinet", help="Название кабинета, например CloudSix")
    g.add_argument("--all-cabinets", action="store_true", help="все WB-кабинеты из secrets/cabinet_api_keys.json")
    p.add_argument("--date-from", required=True, help="YYYY-MM-DD")
    p.add_argument("--date-to", required=True, help="YYYY-MM-DD")
    p.add_argument("--database", help="БД проекта (по умолчанию CLICKHOUSE_DATABASE)")
    p.add_argument("--dry-run", action="store_true", help="только запросить и посчитать, в ClickHouse не писать")
    a = p.parse_args()

    d_from, d_to = date.fromisoformat(a.date_from), date.fromisoformat(a.date_to)
    if d_from > d_to:
        print("Ошибка: date-from позже date-to", file=sys.stderr)
        sys.exit(1)

    failed = []
    for cab in (list_wb_cabinets() if a.all_cabinets else [a.cabinet]):
        try:
            s = ingest_period(cab, d_from, d_to, database=a.database, dry_run=a.dry_run)
            print(f"{cab}: строк {s['rows']}, сумма {s['sum']:,.0f} ₽")
        except Exception as e:  # noqa: BLE001 — один кабинет не валит остальные
            print(f"ОШИБКА {cab}: {e}", file=sys.stderr)
            failed.append(cab)
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
