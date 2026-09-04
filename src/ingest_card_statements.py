#!/usr/bin/env python3
"""
Загрузка справок о движении средств по картам (PDF) в ClickHouse Cloud —
CLI-обёртка над card_statement_pdf.py.

Пример:
    python3 ingest_card_statements.py --project-id 1 --dir "/path/to/ПДФ"
"""

import argparse
import os
import sys
from pathlib import Path

import clickhouse_connect
from dotenv import load_dotenv

from card_statement_pdf import parse_dir, SCRIPT_DIR

load_dotenv(SCRIPT_DIR.parent / ".env")  # .env лежит в корне репозитория, на уровень выше src/

COLUMNS = [
    "project_id", "cardholder", "source_bank", "account_number", "card_number",
    "operation_date", "processing_date", "amount", "signed_amount", "description",
    "row_num", "source_file",
]


def get_client():
    host = os.environ["CLICKHOUSE_HOST"]
    port = int(os.environ.get("CLICKHOUSE_PORT", "8443"))
    user = os.environ.get("CLICKHOUSE_USER", "default")
    password = os.environ["CLICKHOUSE_PASSWORD"]
    database = os.environ.get("CLICKHOUSE_DATABASE", "default")
    secure = os.environ.get("CLICKHOUSE_SECURE", "1") != "0"
    return clickhouse_connect.get_client(
        host=host, port=port, username=user, password=password,
        database=database, secure=secure,
    )


def to_date(value: str):
    if not value:
        return None
    from datetime import datetime
    try:
        return datetime.strptime(value, "%d.%m.%Y").date()
    except ValueError:
        return None


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

    rows = parse_dir(input_dir)
    if not rows:
        print("Ошибка: не найдено ни одной транзакции", file=sys.stderr)
        sys.exit(1)

    for row in rows:
        row["project_id"] = args.project_id
        row["operation_date"] = to_date(row["operation_date"])
        row["processing_date"] = to_date(row["processing_date"])

    cardholders = sorted({r["cardholder"] for r in rows if r["cardholder"]})
    files_count = len(list(input_dir.glob("*.pdf")))
    print(f"Файлов: {files_count}, строк: {len(rows)}")
    print(f"Держатели карт: {cardholders}")

    if args.dry_run:
        print("Dry-run: в ClickHouse ничего не пишу.")
        return

    client = get_client()
    data = [[row.get(col) for col in COLUMNS] for row in rows]
    client.insert("card_statements", data, column_names=COLUMNS)
    print(f"Загружено {len(data)} строк в card_statements.")


if __name__ == "__main__":
    main()
