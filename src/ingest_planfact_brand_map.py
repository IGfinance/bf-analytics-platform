#!/usr/bin/env python3
"""
Загрузка мэппинга "Проекты" ПланФакта -> Бренд/Площадка/Юрлицо в
planfact_brand_map. Источник — вкладка "Бренды" гугл-таблицы Ильяса
(публична по ссылке, см. knowledge/business/2026-09-03 архитектура
финансов Cloudsix в вики), читаем через gviz CSV-экспорт, без API-ключа.

Пример:
    python3 ingest_planfact_brand_map.py --project-id 1
"""

import argparse
import csv
import io
import os
from pathlib import Path

import clickhouse_connect
import requests
from dotenv import load_dotenv

SCRIPT_DIR = Path(__file__).parent
load_dotenv(SCRIPT_DIR.parent / ".env")

SHEET_ID = "1sgddmomCgTbSpcLItlW3t68h0ParmYXLU197nEzNVFA"
SHEET_TAB = "Бренды"
CSV_URL = f"https://docs.google.com/spreadsheets/d/{SHEET_ID}/gviz/tq?tqx=out:csv&sheet={SHEET_TAB}"

# "Название в ПланФакте" в таблице "Бренды" разошлось с реальным текстом
# в выгрузке ПланФакта для Torado/Wb (переименование/опечатка, подтверждено
# Ильясом 2026-09-04) — здесь синоним нормализуется к варианту из выгрузки.
PF_PROJECT_ALIASES = {
    "WB Chromium (ИП Маторин)": "WB Torado (ИП Маторин)",
}

COLUMNS = ["project_id", "pf_project", "brand", "platform", "legal_entity"]


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


def fetch_brand_map() -> list[dict]:
    resp = requests.get(CSV_URL, timeout=30)
    resp.raise_for_status()
    reader = csv.DictReader(io.StringIO(resp.text))

    rows = []
    for r in reader:
        pf_project = (r.get("Название в ПланФакте") or "").strip()
        brand = (r.get("Бренд") or "").strip()
        platform = (r.get("Площадка") or "").strip()
        legal_entity = (r.get("Юрлицо") or "").strip()
        if not pf_project or not brand:
            continue  # бренды без привязанного юрлица (MaxJansen/HomeMaster/Dorri) — нет ключа для джойна
        pf_project = PF_PROJECT_ALIASES.get(pf_project, pf_project)
        rows.append({
            "pf_project": pf_project,
            "brand": brand,
            "platform": platform,
            "legal_entity": legal_entity or None,
        })
    return rows


def main():
    parser = argparse.ArgumentParser(description="Загрузка мэппинга Бренд/Площадка/Юрлицо из ПланФакта")
    parser.add_argument("--project-id", required=True, type=int, help="ID проекта, например 1 для CloudSix")
    parser.add_argument("--dry-run", action="store_true", help="Не писать в ClickHouse, только проверить")
    args = parser.parse_args()

    rows = fetch_brand_map()
    print(f"Строк в мэппинге: {len(rows)}")
    for row in rows:
        row["project_id"] = args.project_id

    if args.dry_run:
        for row in rows:
            print(row)
        print("Dry-run: в ClickHouse ничего не пишу.")
        return

    client = get_client()
    data = [[row.get(col) for col in COLUMNS] for row in rows]
    client.insert("planfact_brand_map", data, column_names=COLUMNS)
    print(f"Загружено {len(data)} строк в planfact_brand_map.")


if __name__ == "__main__":
    main()
