#!/usr/bin/env python3
"""
Загрузка отчётов WB (xlsx) в ClickHouse Cloud — CLI-обёртка над wb_core.py.

Использует column_mapping_wb.yaml для сопоставления заголовков колонок
(которые WB время от времени переименовывает или добавляет) с каноническими
полями таблицы wb_reports.

Колонки, которых нет в маппинге, не блокируют загрузку — их значения
уходят в extra_columns (Map), а сам факт "встретил неизвестную колонку"
пишется в unmapped_columns_log и выводится в консоль.

Пример:
    python3 ingest_wb.py --cabinet "AcmeShop" --files "/path/to/reports/*.xlsx"
"""

import argparse
import glob
import sys
from pathlib import Path

from dotenv import load_dotenv

from wb_core import ingest_files, load_mapping, process_file, SCRIPT_DIR

load_dotenv(SCRIPT_DIR.parent / ".env")  # .env лежит в корне репозитория, на уровень выше src/


def main():
    parser = argparse.ArgumentParser(description="Загрузка отчётов WB в ClickHouse")
    parser.add_argument("--cabinet", required=True, help="Название кабинета, например AcmeShop")
    parser.add_argument("--files", required=True, help="Путь к файлу(ам), можно с маской *.xlsx")
    parser.add_argument("--dry-run", action="store_true", help="Не писать в ClickHouse, только проверить")
    args = parser.parse_args()

    files = sorted(Path(p) for p in glob.glob(args.files))
    if not files:
        print(f"Ошибка: не найдено файлов по пути {args.files}", file=sys.stderr)
        sys.exit(1)

    if args.dry_run:
        alias_to_canonical, canonical_type = load_mapping()
        total_rows = 0
        unmapped_seen = set()
        for path in files:
            rows, _ = process_file(path, args.cabinet, alias_to_canonical, canonical_type, unmapped_seen)
            total_rows += len(rows)
        print(f"\nВсего строк: {total_rows}")
        print(f"Неизвестных колонок: {len(unmapped_seen)}")
        print("Dry-run: в ClickHouse ничего не пишу.")
        return

    summary = ingest_files(files, args.cabinet)
    if summary["unmapped_columns"]:
        print("Проверьте и обновите column_mapping_wb.yaml для колонок:", summary["unmapped_columns"])


if __name__ == "__main__":
    main()
