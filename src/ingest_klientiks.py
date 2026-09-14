#!/usr/bin/env python3
"""
Загрузка выгрузок Клиентикс (CSV) в ClickHouse — CLI-обёртка над
klientiks_core.py. Удобно для пакетной заливки истории (несколько годовых
файлов сразу), в отличие от загрузки по одному через веб-форму.

Пример:
    python3 ingest_klientiks.py --project-id 2 --dir "/path/to/Клиентикс"
"""

import argparse
import sys
from pathlib import Path

from dotenv import load_dotenv

from klientiks_core import parse_file, ingest_files, SCRIPT_DIR

load_dotenv(SCRIPT_DIR.parent / ".env")  # .env лежит в корне репозитория, на уровень выше src/


def main():
    parser = argparse.ArgumentParser(description="Загрузка выгрузок Клиентикс (CSV) в ClickHouse")
    parser.add_argument("--project-id", required=True, type=int, help="ID проекта (например, Реальт)")
    parser.add_argument("--dir", required=True, help="Путь к папке с CSV-выгрузками Клиентикс")
    parser.add_argument("--dry-run", action="store_true", help="Не писать в ClickHouse, только проверить")
    args = parser.parse_args()

    input_dir = Path(args.dir)
    if not input_dir.is_dir():
        print(f"Ошибка: не найдена папка {input_dir}", file=sys.stderr)
        sys.exit(1)

    files = sorted(input_dir.glob("*.csv"))
    if not files:
        print(f"Ошибка: не найдено ни одного .csv в {input_dir}", file=sys.stderr)
        sys.exit(1)

    if args.dry_run:
        total, skipped = 0, 0
        for p in files:
            rows, sk = parse_file(p)
            total += len(rows)
            skipped += sk
        print(f"Файлов: {len(files)}, строк: {total}, пропущено: {skipped}")
        print("Dry-run: в ClickHouse ничего не пишу.")
        return

    try:
        summary = ingest_files(files, project_id=args.project_id)
    except ValueError as e:
        print(f"Ошибка: {e}", file=sys.stderr)
        sys.exit(1)
    print(f"Файлов: {summary['files']}, строк: {summary['rows']}, пропущено: {summary['skipped']}")


if __name__ == "__main__":
    main()
