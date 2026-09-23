#!/usr/bin/env python3
"""
Загрузка отчёта Ozon "Взаиморасчёты" (/v1/finance/cash-flow-statement/list)
в ClickHouse — источник для сверки итоговой суммы к перечислению и для
статей, не привязанных к конкретному товару/отправлению (реклама, склад,
подписки). См. schema_ozon_cashflow.sql.

Запрашивается напрямую по календарному месяцу (date.from/to) — периоды
выплат (~неделя), которые Ozon возвращает, не пересекают границы месяца,
когда запрос идёт по одному месяцу (проверено эмпирически на CloudSix).
Поэтому, в отличие от accrual/postings, здесь не нужен lookback назад.
"""

import os
import time
from datetime import date, datetime, timedelta

import clickhouse_connect
import requests

from cabinet_credentials import get_ozon_credentials

URL = "https://api-seller.ozon.ru/v1/finance/cash-flow-statement/list"
MAX_RETRIES = 6


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


def _parse_dt(value: str) -> date:
    return datetime.strptime(value[:10], "%Y-%m-%d").date()


PERIOD_COLUMNS = [
    "cabinet", "period_begin", "period_end", "begin_balance_amount", "invoice_transfer", "loan",
    "payments_total", "delivery_amount", "delivery_services_total", "delivery_total",
    "return_amount", "return_services_total", "return_total", "rfbs_total",
    "services_total", "others_total", "currency",
]
ITEM_COLUMNS = ["cabinet", "period_begin", "bucket", "item_name", "price", "line_number"]


def rows_from_response(cabinet: str, body: dict) -> tuple[list[dict], list[dict]]:
    details = body.get("result", {}).get("details", [])
    period_rows = []
    item_rows = []

    for d in details:
        period_begin = _parse_dt(d["period"]["begin"])
        period_end = _parse_dt(d["period"]["end"])
        delivery = d.get("delivery") or {}
        ret = d.get("return") or {}
        rfbs = d.get("rfbs") or {}
        services = d.get("services") or {}
        others = d.get("others") or {}
        currency = (d.get("payments") or [{}])[0].get("currency_code", "RUB")

        period_rows.append({
            "cabinet": cabinet,
            "period_begin": period_begin,
            "period_end": period_end,
            "begin_balance_amount": d.get("begin_balance_amount") or 0,
            "invoice_transfer": d.get("invoice_transfer") or 0,
            "loan": d.get("loan") or 0,
            "payments_total": sum(p.get("payment") or 0 for p in d.get("payments") or []),
            "delivery_amount": delivery.get("amount") or 0,
            "delivery_services_total": (delivery.get("delivery_services") or {}).get("total") or 0,
            "delivery_total": delivery.get("total") or 0,
            "return_amount": ret.get("amount") or 0,
            "return_services_total": (ret.get("return_services") or {}).get("total") or 0,
            "return_total": ret.get("total") or 0,
            "rfbs_total": rfbs.get("total") or 0,
            "services_total": services.get("total") or 0,
            "others_total": others.get("total") or 0,
            "currency": currency,
        })

        for bucket, items in (
            ("delivery_services", (delivery.get("delivery_services") or {}).get("items") or []),
            ("return_services", (ret.get("return_services") or {}).get("items") or []),
            ("services", services.get("items") or []),
            ("others", others.get("items") or []),
        ):
            for line_number, item in enumerate(items, start=1):
                item_rows.append({
                    "cabinet": cabinet,
                    "period_begin": period_begin,
                    "bucket": bucket,
                    "item_name": item.get("name", ""),
                    "price": item.get("price") or 0,
                    "line_number": line_number,
                })

    return period_rows, item_rows


def ingest_month(cabinet: str, year: int, month: int, log=print) -> dict:
    client_id, api_key = get_ozon_credentials(cabinet)
    headers = {"Client-Id": client_id, "Api-Key": api_key, "Content-Type": "application/json"}

    month_start = date(year, month, 1)
    next_month_start = date(year + 1, 1, 1) if month == 12 else date(year, month + 1, 1)
    month_end = next_month_start - timedelta(days=1)
    # "to" — конец последнего дня месяца (23:59:59), НЕ первое число следующего месяца:
    # с границей "00:00:00 первого числа следующего месяца" Ozon отдавал лишний
    # однодневный период, начинающийся ровно в этот момент (см. баг на CloudSix —
    # период 2026-09-01..2026-09-06 просочился в выгрузку за август).
    payload = {
        "date": {"from": f"{month_start.isoformat()}T00:00:00.000Z", "to": f"{month_end.isoformat()}T23:59:59.000Z"},
        "page": 1, "page_size": 20, "with_details": True,
    }
    body = _post_with_retry(URL, payload, headers)
    page_count = body.get("result", {}).get("page_count", 1)
    if page_count > 1:
        log(f"  ВНИМАНИЕ: {year}-{month:02d} — {page_count} страниц, загружена только первая (проверить лимиты)")

    period_rows, item_rows = rows_from_response(cabinet, body)

    client = get_client()
    if period_rows:
        data = [[r[c] for c in PERIOD_COLUMNS] for r in period_rows]
        client.insert("ozon_cashflow_periods", data, column_names=PERIOD_COLUMNS)
    if item_rows:
        data = [[r[c] for c in ITEM_COLUMNS] for r in item_rows]
        client.insert("ozon_cashflow_items", data, column_names=ITEM_COLUMNS)

    log(f"  {year}-{month:02d}: {len(period_rows)} период(ов), {len(item_rows)} строк-статей.")
    return {"periods": len(period_rows), "items": len(item_rows)}
