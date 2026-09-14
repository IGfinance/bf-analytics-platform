#!/usr/bin/env python3
"""
Загрузка банковских выписок 1С (txt) в ClickHouse Cloud — CLI-обёртка над
bank_statement_1c.py.

Пример:
    python3 ingest_bank_statements.py --project-id 1 --dir "/path/to/1C"
"""

import argparse
import sys
from pathlib import Path

from dotenv import load_dotenv

from bank_statement_1c import parse_dir, ingest_files, SCRIPT_DIR

load_dotenv(SCRIPT_DIR.parent / ".env")  # .env лежит в корне репозитория, на уровень выше src/


def main():
    parser = argparse.ArgumentParser(description="Загрузка банковских выписок 1С в ClickHouse")
    parser.add_argument("--project-id", required=True, type=int, help="ID проекта, например 1 для CloudSix")
    parser.add_argument("--dir", required=True, help="Путь к папке с txt-выписками 1С")
    parser.add_argument("--dry-run", action="store_true", help="Не писать в ClickHouse, только проверить")
    args = parser.parse_args()

    input_dir = Path(args.dir)
    if not input_dir.is_dir():
        print(f"Ошибка: не найдена папка {input_dir}", file=sys.stderr)
        sys.exit(1)

    if args.dry_run:
        rows = parse_dir(input_dir)
        if not rows:
            print("Ошибка: не найдено ни одной транзакции", file=sys.stderr)
            sys.exit(1)
        extra_keys = sorted({k for r in rows for k in r["extra_columns"]})
        files_count = len(list(input_dir.glob("*.txt")))
        print(f"Файлов: {files_count}, строк: {len(rows)}")
        print(f"Ключи в extra_columns: {extra_keys}")
        print("Dry-run: в ClickHouse ничего не пишу.")
        return

    files = sorted(input_dir.glob("*.txt"))
    try:
        summary = ingest_files(files, project_id=args.project_id)
    except ValueError as e:
        print(f"Ошибка: {e}", file=sys.stderr)
        sys.exit(1)
    print(f"Файлов: {summary['files']}, строк: {summary['rows']}")
    print(f"Ключи в extra_columns: {summary['extra_columns']}")


if __name__ == "__main__":
    main()
