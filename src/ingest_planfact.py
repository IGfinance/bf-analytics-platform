#!/usr/bin/env python3
"""
Загрузка сырой выгрузки ПланФакта (xlsx) в ClickHouse Cloud — CLI-обёртка
над planfact_xlsx.py.

Пример:
    python3 ingest_planfact.py --project-id 1 --file "/path/to/Выписка.xlsx"
"""

import argparse
import os
import sys
from pathlib import Path

import clickhouse_connect
from dotenv import load_dotenv

from planfact_xlsx import parse_xlsx, SCRIPT_DIR

load_dotenv(SCRIPT_DIR.parent / ".env")  # .env лежит в корне репозитория, на уровень выше src/

COLUMNS = [
    "project_id", "row_num", "payment_date", "payment_status", "accrual_date",
    "accrual_status", "counterparty", "counterparty_inn", "operation_type",
    "account_name", "account_number", "bank_name", "bik", "legal_entity",
    "legal_entity_inn", "statya", "parent_statya", "activity_type",
    "payment_purpose", "pf_project", "amount", "currency", "source_file",
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
    parser = argparse.ArgumentParser(description="Загрузка выгрузки ПланФакта в ClickHouse")
    parser.add_argument("--project-id", required=True, type=int, help="ID проекта, например 1 для CloudSix")
    parser.add_argument("--file", required=True, help="Путь к xlsx-файлу выгрузки ПланФакта")
    parser.add_argument("--dry-run", action="store_true", help="Не писать в ClickHouse, только проверить")
    args = parser.parse_args()

    input_file = Path(args.file)
    if not input_file.is_file():
        print(f"Ошибка: не найден файл {input_file}", file=sys.stderr)
        sys.exit(1)

    rows = parse_xlsx(input_file)
    if not rows:
        print("Ошибка: не найдено ни одной транзакции", file=sys.stderr)
        sys.exit(1)

    for row in rows:
        row["project_id"] = args.project_id

    with_project = sum(1 for r in rows if r.get("pf_project"))
    print(f"Строк: {len(rows)}, с заполненным pf_project: {with_project} ({with_project / len(rows):.0%})")

    if args.dry_run:
        print("Dry-run: в ClickHouse ничего не пишу.")
        return

    client = get_client()
    data = [[row.get(col) for col in COLUMNS] for row in rows]
    client.insert("planfact_transactions", data, column_names=COLUMNS)
    print(f"Загружено {len(data)} строк в planfact_transactions.")

    log_unmapped_projects(client, args.project_id, rows, input_file.name)


def log_unmapped_projects(client, project_id: int, rows: list[dict], source_file: str) -> None:
    """Пишет в planfact_unmapped_project_log значения pf_project, для которых
    нет пары в planfact_brand_map — видимость пробела в справочнике "Бренды"
    при каждой перезаливке, а не разовая находка вручную (см. историю с
    "MY"/HomeMaster, 2026-09-04)."""
    known = {r[0] for r in client.query(
        "SELECT pf_project FROM planfact_brand_map WHERE project_id = {pid:UInt32}",
        parameters={"pid": project_id},
    ).result_rows}

    counts: dict[str, int] = {}
    for row in rows:
        pf_project = row.get("pf_project")
        if pf_project and pf_project not in known:
            counts[pf_project] = counts.get(pf_project, 0) + 1

    if not counts:
        return

    log_columns = ["project_id", "pf_project", "rows_count", "source_file"]
    log_data = [[project_id, pf_project, count, source_file] for pf_project, count in counts.items()]
    client.insert("planfact_unmapped_project_log", log_data, column_names=log_columns)
    print(f"Не смэплено на planfact_brand_map: {counts} — записано в planfact_unmapped_project_log.")


if __name__ == "__main__":
    main()
