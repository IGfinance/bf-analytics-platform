#!/usr/bin/env python3
"""
Загрузка банковских выписок 1С (txt) в ClickHouse Cloud — CLI-обёртка над
bank_statement_1c.py.

Пример:
    python3 ingest_bank_statements.py --project-id 1 --dir "/path/to/1C"
"""

import argparse
import os
import sys
from pathlib import Path

import clickhouse_connect
from dotenv import load_dotenv

from bank_statement_1c import parse_dir, SCRIPT_DIR

load_dotenv(SCRIPT_DIR.parent / ".env")  # .env лежит в корне репозитория, на уровень выше src/

COLUMNS = [
    "project_id", "account_number", "source_bank", "doc_type", "doc_number",
    "doc_date", "effective_date", "direction", "amount", "signed_amount",
    "counterparty", "counterparty_inn", "counterparty_account", "counterparty_bank",
    "counterparty_bik", "counterparty_kpp", "payment_purpose", "payment_kind",
    "priority", "row_num", "extra_columns", "source_file",
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

    rows = parse_dir(input_dir)
    if not rows:
        print("Ошибка: не найдено ни одной транзакции", file=sys.stderr)
        sys.exit(1)

    for row in rows:
        row["project_id"] = args.project_id

    extra_keys = sorted({k for r in rows for k in r["extra_columns"]})
    files_count = len(list(input_dir.glob("*.txt")))
    print(f"Файлов: {files_count}, строк: {len(rows)}")
    print(f"Ключи в extra_columns: {extra_keys}")

    if args.dry_run:
        print("Dry-run: в ClickHouse ничего не пишу.")
        return

    client = get_client()
    data = [[row.get(col) for col in COLUMNS] for row in rows]
    client.insert("bank_statements", data, column_names=COLUMNS)
    print(f"Загружено {len(data)} строк в bank_statements.")


if __name__ == "__main__":
    main()
