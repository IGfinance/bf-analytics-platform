#!/usr/bin/env python3
"""
Загрузка справок о движении средств по картам (PDF) в ClickHouse Cloud —
CLI-обёртка над card_statement_pdf.py.

Пример:
    python3 ingest_card_statements.py --project-id 1 --dir "/path/to/ПДФ"
"""

import argparse
import sys
from pathlib import Path

from dotenv import load_dotenv

from card_statement_pdf import parse_dir, ingest_files, SCRIPT_DIR

load_dotenv(SCRIPT_DIR.parent / ".env")  # .env лежит в корне репозитория, на уровень выше src/


def main():
    parser = argparse.ArgumentParser(description="Загрузка карточных выписок (PDF) в ClickHouse")
    parser.add_argument("--project-id", required=True, type=int, help="ID проекта, например 1 для CloudSix")
    parser.add_argument("--dir", required=True, help="Путь к папке с PDF-справками")
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
        cardholders = sorted({r["cardholder"] for r in rows if r["cardholder"]})
        files_count = len(list(input_dir.glob("*.pdf")))
        print(f"Файлов: {files_count}, строк: {len(rows)}")
        print(f"Держатели карт: {cardholders}")
        print("Dry-run: в ClickHouse ничего не пишу.")
        return

    files = sorted(input_dir.glob("*.pdf"))
    try:
        summary = ingest_files(files, project_id=args.project_id)
    except ValueError as e:
        print(f"Ошибка: {e}", file=sys.stderr)
        sys.exit(1)
    print(f"Файлов: {summary['files']}, строк: {summary['rows']}")
    print(f"Держатели карт: {summary['cardholders']}")


if __name__ == "__main__":
    main()
