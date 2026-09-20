#!/usr/bin/env python3
"""
Загрузка финансовых операций Ozon через Seller API (v3/finance/transaction/list)
напрямую в ClickHouse — источник данных, альтернативный ручной выгрузке
.xlsx "Начисления" (см. ozon_core.py). Метод отдаёт только уже проведённые
начисления (нет статусов "в обработке") — фильтрация по статусу не нужна.

Пагинация — по page/page_size (макс. 1000 строк/страницу), до исчерпания
page_count. У Ozon нет отдельного строгого rate-limit для этого метода
(в отличие от WB), но всё равно есть общий лимит запросов в минуту —
ретраим на HTTP 429 с экспоненциальной паузой.
"""

import os
import time
from datetime import datetime, date

import clickhouse_connect
import requests

from cabinet_credentials import get_ozon_credentials

API_URL = "https://api-seller.ozon.ru/v3/finance/transaction/list"
PAGE_SIZE = 1000
MAX_RETRIES = 6


def _request_page(client_id: str, api_key: str, date_from: str, date_to: str, page: int) -> dict:
    payload = {
        "filter": {
            "date": {"from": f"{date_from}T00:00:00.000Z", "to": f"{date_to}T23:59:59.000Z"},
            "transaction_type": "all",
        },
        "page": page,
        "page_size": PAGE_SIZE,
    }
    headers = {"Client-Id": client_id, "Api-Key": api_key, "Content-Type": "application/json"}

    delay = 5
    for attempt in range(MAX_RETRIES):
        resp = requests.post(API_URL, json=payload, headers=headers, timeout=60)
        if resp.status_code == 429:
            time.sleep(delay)
            delay = min(delay * 2, 60)
            continue
        resp.raise_for_status()
        return resp.json()["result"]
    raise RuntimeError(f"Ozon API: не удалось получить страницу {page} после {MAX_RETRIES} попыток (429)")


def fetch_operations(client_id: str, api_key: str, date_from: str, date_to: str, log=print):
    """Генератор операций за период [date_from, date_to] (включительно, формат YYYY-MM-DD)."""
    page = 1
    while True:
        result = _request_page(client_id, api_key, date_from, date_to, page)
        operations = result["operations"]
        page_count = result["page_count"]
        log(f"    Ozon API: страница {page}/{page_count}, операций: {len(operations)}")
        for op in operations:
            yield op
        if page >= page_count or not operations:
            break
        page += 1


def _parse_dt(value):
    if not value:
        return None
    return datetime.strptime(value, "%Y-%m-%d %H:%M:%S")


def operation_to_row(op: dict, cabinet: str, date_from: date, date_to: date) -> dict:
    posting = op.get("posting") or {}
    services = op.get("services") or []
    items = op.get("items") or []
    return {
        "cabinet": cabinet,
        "operation_id": op["operation_id"],
        "operation_type": op.get("operation_type", ""),
        "operation_type_name": op.get("operation_type_name", ""),
        "operation_date": _parse_dt(op.get("operation_date")),
        "delivery_charge": op.get("delivery_charge") or 0,
        "return_delivery_charge": op.get("return_delivery_charge") or 0,
        "accruals_for_sale": op.get("accruals_for_sale") or 0,
        "sale_commission": op.get("sale_commission") or 0,
        "amount": op.get("amount") or 0,
        "type": op.get("type", ""),
        "posting_number": posting.get("posting_number"),
        "posting_delivery_schema": posting.get("delivery_schema"),
        "posting_order_date": _parse_dt(posting.get("order_date")),
        "posting_warehouse_id": posting.get("warehouse_id"),
        "item_names": [i.get("name", "") for i in items],
        "item_skus": [i.get("sku", 0) for i in items],
        "service_names": [s.get("name", "") for s in services],
        "service_prices": [s.get("price", 0) for s in services],
        "source_date_from": date_from,
        "source_date_to": date_to,
    }


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


ROW_COLUMNS = [
    "cabinet", "operation_id", "operation_type", "operation_type_name", "operation_date",
    "delivery_charge", "return_delivery_charge", "accruals_for_sale", "sale_commission", "amount",
    "type", "posting_number", "posting_delivery_schema", "posting_order_date", "posting_warehouse_id",
    "item_names", "item_skus", "service_names", "service_prices",
    "source_date_from", "source_date_to",
]


def ingest_period(cabinet: str, date_from: date, date_to: date, log=print) -> dict:
    client_id, api_key = get_ozon_credentials(cabinet)

    rows = [
        operation_to_row(op, cabinet, date_from, date_to)
        for op in fetch_operations(client_id, api_key, date_from.isoformat(), date_to.isoformat(), log=log)
    ]

    if not rows:
        log("  Ozon API: операций за период не найдено.")
        return {"rows": 0}

    client = get_client()
    data = [[row[col] for col in ROW_COLUMNS] for row in rows]
    client.insert("ozon_api_transactions", data, column_names=ROW_COLUMNS)
    log(f"  Загружено {len(data)} операций в ozon_api_transactions.")
    return {"rows": len(data)}
