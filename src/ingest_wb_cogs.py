#!/usr/bin/env python3
"""
Загрузка файла себестоимости по неделям в ClickHouse — CLI-обёртка над
wb_cogs_core.py (см. schema_wb_cogs.sql про формат таблицы).

Примеры:
    python3 ingest_wb_cogs.py --file "../data-files/СС CloudSix от 14.09.26 (1).xlsx"
    python3 ingest_wb_cogs.py --file <путь> --sheet "CC общ" --dry-run
"""

import argparse
import logging
import sys
from pathlib import Path

from dotenv import load_dotenv

SCRIPT_DIR = Path(__file__).parent
REPO_ROOT = SCRIPT_DIR.parent
load_dotenv(REPO_ROOT / ".env")

from wb_cogs_core import DEFAULT_SHEET, ingest_file, parse_file  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description="Загрузка себестоимости по неделям (.xlsx) в ClickHouse")
    parser.add_argument("--file", required=True, help="Путь к файлу себестоимости .xlsx")
    parser.add_argument("--sheet", default=DEFAULT_SHEET, help=f"Имя листа (по умолчанию {DEFAULT_SHEET!r})")
    parser.add_argument("--dry-run", action="store_true", help="Только разобрать файл и показать сводку, без записи в БД")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")

    try:
        if args.dry_run:
            rows = parse_file(args.file, args.sheet)
            weeks = {r[1] for r in rows}
            print(f"dry-run: {len(rows)} строк, {len({r[0] for r in rows})} артикулов, "
                  f"{len(weeks)} недель ({min(weeks)}..{max(weeks)}). В БД не записано.")
            return
        summary = ingest_file(args.file, args.sheet)
    except Exception as e:
        print(f"ОШИБКА: {e}", file=sys.stderr)
        sys.exit(1)

    print(f"Загружено строк: {summary['rows']}, артикулов: {summary['skus']}, "
          f"недель: {summary['weeks']} ({summary['week_min']}..{summary['week_max']}).")


if __name__ == "__main__":
    main()
