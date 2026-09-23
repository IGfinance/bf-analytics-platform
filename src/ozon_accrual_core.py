#!/usr/bin/env python3
"""
Загрузка операционной детализации Ozon через /v1/finance/accrual/postings —
батчами по posting_number (до 200 за запрос), плюс справочник типов
начислений /v1/finance/accrual/types. См. schema_ozon_accrual.sql.

Пайплайн на месяц: список отправлений (ozon_postings_core.list_all_postings)
-> батчи по 200 -> accrual/postings -> разбор -> вставка в ozon_accruals.
"""

import os
import time
from datetime import date, datetime

import clickhouse_connect
import requests

from cabinet_credentials import get_ozon_credentials
from ozon_postings_core import list_all_postings, POSTING_COLUMNS

ACCRUAL_URL = "https://api-seller.ozon.ru/v1/finance/accrual/postings"
TYPES_URL = "https://api-seller.ozon.ru/v1/finance/accrual/types"
BATCH_SIZE = 200
MAX_RETRIES = 6
# Окно поиска отправлений (шире месяца) задаётся в ozon_postings_core.list_all_postings
# (lookback_days=90 по умолчанию) — см. её docstring про лаг между созданием и accrual_date.

# type_id=0 не встречается в реальном справочнике Ozon (id там с 1) — используем как
# синтетическую строку выручки. В accrual/postings нет отдельной строки-начисления под сумму
# продажи: она "приклеена" как seller_price к строке SaleCommission (per-unit, seller_price *
# quantity — сверено день-в-день со старым accruals_for_sale, включая знак у возвратов, где
# seller_price отрицательный). Без этой строки sum(accrued_amount) считает только вычеты,
# без самой выручки — то есть получается в разы меньше (и часто с обратным знаком) реальных денег.
REVENUE_TYPE_ID = 0


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


def _post_with_retry(url: str, payload: dict, headers: dict) -> dict:
    delay = 5
    for _ in range(MAX_RETRIES):
        resp = requests.post(url, json=payload, headers=headers, timeout=60)
        if resp.status_code == 429 or resp.status_code >= 500:
            time.sleep(delay)
            delay = min(delay * 2, 60)
            continue
        resp.raise_for_status()
        return resp.json()
    raise RuntimeError(f"Ozon API: не удалось получить {url} после {MAX_RETRIES} попыток (429/5xx)")


def fetch_accrual_types(cabinet_for_auth: str, log=print) -> list[dict]:
    """Справочник типов — общий для площадки, но запрос всё равно требует Client-Id/Api-Key
    какого-нибудь кабинета (используется для авторизации, не для фильтрации данных)."""
    client_id, api_key = get_ozon_credentials(cabinet_for_auth)
    headers = {"Client-Id": client_id, "Api-Key": api_key, "Content-Type": "application/json"}
    body = _post_with_retry(TYPES_URL, {}, headers)
    types = body.get("accrual_types", [])
    log(f"Справочник accrual_types: {len(types)} записей.")
    return [{"type_id": t["id"], "name": t["name"], "description": t.get("description", "")} for t in types]


def ingest_accrual_types(cabinet_for_auth: str, log=print) -> int:
    types = fetch_accrual_types(cabinet_for_auth, log=log)
    types.append({
        "type_id": REVENUE_TYPE_ID,
        "name": "SellerRevenue",
        "description": "Синтетическая строка — восстановленная выручка (seller_price × quantity "
                        "со строк SaleCommission). Не из справочника Ozon, добавлена ozon_accrual_core.py.",
    })
    client = get_client()
    columns = ["type_id", "name", "description"]
    data = [[t[c] for c in columns] for t in types]
    client.insert("ozon_accrual_types", data, column_names=columns)
    log(f"Загружено {len(data)} строк в ozon_accrual_types (включая синтетический SellerRevenue).")
    return len(data)


def _chunk(items: list, size: int):
    for i in range(0, len(items), size):
        yield items[i:i + size]


def _to_float(money):
    if money is None:
        return None
    return float(money["amount"])


def rows_from_accrual_response(cabinet: str, body: dict) -> list[dict]:
    rows = []
    for pa in body.get("posting_accruals", []):
        posting_number = pa["posting_number"]
        for line_number, acc in enumerate(pa.get("accruals", []), start=1):
            accrued = acc.get("accrued") or {}
            accrual_date = datetime.strptime(acc["accrual_date"], "%Y-%m-%d").date()
            currency = accrued.get("currency", "RUB")
            seller_price = _to_float(acc.get("seller_price"))
            quantity = acc.get("quantity", 0)
            sku = acc.get("sku", 0)

            rows.append({
                "cabinet": cabinet,
                "posting_number": posting_number,
                "line_number": line_number,
                "type_id": acc.get("type_id", 0),
                "accrued_amount": float(accrued.get("amount") or 0),
                "currency": currency,
                "accrual_date": accrual_date,
                "seller_price": seller_price,
                "sku": sku,
                "quantity": quantity,
            })

            # Синтетическая строка выручки — см. REVENUE_TYPE_ID выше. line_number со
            # знаком минус гарантирует уникальность в ORDER BY (реальные всегда >= 1).
            if seller_price is not None:
                rows.append({
                    "cabinet": cabinet,
                    "posting_number": posting_number,
                    "line_number": -line_number,
                    "type_id": REVENUE_TYPE_ID,
                    "accrued_amount": seller_price * quantity,
                    "currency": currency,
                    "accrual_date": accrual_date,
                    "seller_price": None,
                    "sku": sku,
                    "quantity": quantity,
                })
    return rows


ACCRUAL_COLUMNS = [
    "cabinet", "posting_number", "line_number", "type_id", "accrued_amount",
    "currency", "accrual_date", "seller_price", "sku", "quantity",
]


def ingest_month(cabinet: str, year: int, month: int, log=print) -> dict:
    client_id, api_key = get_ozon_credentials(cabinet)

    postings = list_all_postings(client_id, api_key, cabinet, year, month, log=log)
    log(f"  {year}-{month:02d}: найдено отправлений {len(postings)}")

    client = get_client()
    if postings:
        posting_data = [[p[c] for c in POSTING_COLUMNS] for p in postings]
        client.insert("ozon_postings", posting_data, column_names=POSTING_COLUMNS)

    posting_numbers = [p["posting_number"] for p in postings]
    total_accrual_rows = 0
    for batch in _chunk(posting_numbers, BATCH_SIZE):
        body = _post_with_retry(ACCRUAL_URL, {"posting_numbers": batch}, {
            "Client-Id": client_id, "Api-Key": api_key, "Content-Type": "application/json",
        })
        rows = rows_from_accrual_response(cabinet, body)
        if rows:
            data = [[r[c] for c in ACCRUAL_COLUMNS] for r in rows]
            client.insert("ozon_accruals", data, column_names=ACCRUAL_COLUMNS)
        total_accrual_rows += len(rows)

    log(f"  {year}-{month:02d}: загружено {total_accrual_rows} строк начислений "
        f"по {len(posting_numbers)} отправлениям.")
    return {"postings": len(postings), "accrual_rows": total_accrual_rows}
