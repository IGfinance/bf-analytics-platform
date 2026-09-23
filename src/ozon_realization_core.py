#!/usr/bin/env python3
"""
Загрузка помесячного отчёта Ozon "Продажи и возвраты" (/v2/finance/realization)
в ClickHouse — источник взамен /v3/finance/transaction/list, который Ozon
отключил в 2026 году (см. schema_ozon_realization.sql про отличия от
ozon_api_transactions).

Метод отдаёт данные строго за 1 календарный месяц (year/month), без
пагинации. Если отчёта за месяц ещё нет (кабинет не работал/не было
продаж), Ozon отвечает 404 {"code":5,"message":"Report was not found"} —
это не ошибка, а "данных нет", обрабатывается отдельно от прочих сбоев.
"""

import os
import time
from datetime import date, datetime

import clickhouse_connect
import requests

from cabinet_credentials import get_ozon_credentials

API_URL = "https://api-seller.ozon.ru/v2/finance/realization"
MAX_RETRIES = 6


class ReportNotFound(Exception):
    """Ozon ответил 404 code=5 — отчёта за этот месяц нет (не сбой)."""


def _request_report(client_id: str, api_key: str, year: int, month: int) -> dict:
    headers = {"Client-Id": client_id, "Api-Key": api_key, "Content-Type": "application/json"}
    payload = {"month": month, "year": year}

    delay = 5
    for attempt in range(MAX_RETRIES):
        resp = requests.post(API_URL, json=payload, headers=headers, timeout=60)
        if resp.status_code == 429:
            time.sleep(delay)
            delay = min(delay * 2, 60)
            continue
        if resp.status_code == 404:
            body = resp.json() if resp.content else {}
            if body.get("code") == 5:
                raise ReportNotFound(f"{year}-{month:02d}")
            resp.raise_for_status()
        resp.raise_for_status()
        return resp.json()["result"]
    raise RuntimeError(f"Ozon API: не удалось получить отчёт {year}-{month:02d} после {MAX_RETRIES} попыток (429)")


def _parse_date(value):
    return datetime.strptime(value, "%Y-%m-%d").date() if value else None


def rows_from_report(cabinet: str, report_month: date, result: dict) -> list[dict]:
    header = result.get("header", {})
    rows = []
    for r in result.get("rows", []):
        item = r.get("item") or {}
        for kind, comm in (("delivery", r.get("delivery_commission")), ("return", r.get("return_commission"))):
            if not comm:
                continue
            rows.append({
                "cabinet": cabinet,
                "report_month": report_month,
                "report_number": header.get("number", ""),
                "doc_date": _parse_date(header.get("doc_date")),
                "start_date": _parse_date(header.get("start_date")),
                "stop_date": _parse_date(header.get("stop_date")),
                "receiver_name": header.get("receiver_name", ""),
                "receiver_inn": header.get("receiver_inn", ""),
                "row_number": r.get("rowNumber", 0),
                "kind": kind,
                "item_name": item.get("name", ""),
                "offer_id": item.get("offer_id", ""),
                "barcode": item.get("barcode", ""),
                "sku": item.get("sku", 0),
                "seller_price_per_instance": r.get("seller_price_per_instance") or 0,
                "commission_ratio": r.get("commission_ratio") or 0,
                "price_per_instance": comm.get("price_per_instance") or 0,
                "quantity": comm.get("quantity") or 0,
                "amount": comm.get("amount") or 0,
                "compensation": comm.get("compensation") or 0,
                "commission": comm.get("commission") or 0,
                "bonus": comm.get("bonus") or 0,
                "standard_fee": comm.get("standard_fee") or 0,
                "total": comm.get("total") or 0,
                "stars": comm.get("stars") or 0,
                "bank_coinvestment": comm.get("bank_coinvestment") or 0,
                "pick_up_point_coinvestment": comm.get("pick_up_point_coinvestment") or 0,
            })
    return rows


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
    "cabinet", "report_month", "report_number", "doc_date", "start_date", "stop_date",
    "receiver_name", "receiver_inn", "row_number", "kind", "item_name", "offer_id",
    "barcode", "sku", "seller_price_per_instance", "commission_ratio",
    "price_per_instance", "quantity", "amount", "compensation", "commission",
    "bonus", "standard_fee", "total", "stars", "bank_coinvestment", "pick_up_point_coinvestment",
]


def ingest_month(cabinet: str, year: int, month: int, log=print) -> dict:
    client_id, api_key = get_ozon_credentials(cabinet)
    report_month = date(year, month, 1)

    try:
        result = _request_report(client_id, api_key, year, month)
    except ReportNotFound:
        log(f"  {year}-{month:02d}: отчёта нет (Report was not found) — пропускаю.")
        return {"rows": 0, "found": False}

    rows = rows_from_report(cabinet, report_month, result)
    if not rows:
        log(f"  {year}-{month:02d}: отчёт есть, но 0 строк.")
        return {"rows": 0, "found": True}

    client = get_client()
    data = [[row[col] for col in ROW_COLUMNS] for row in rows]
    client.insert("ozon_realization", data, column_names=ROW_COLUMNS)
    log(f"  {year}-{month:02d}: загружено {len(data)} строк в ozon_realization.")
    return {"rows": len(data), "found": True}
