#!/usr/bin/env python3
"""
Списки отправлений Ozon за период — FBS (/v3/posting/fbs/list) и FBO
(/v2/posting/fbo/list). Нужны как источник posting_number для батчей в
/v1/finance/accrual/postings (тот метод не принимает диапазон дат, только
конкретные номера отправлений) — см. schema_ozon_accrual.sql.

У площадок разные лимиты пагинации: FBS — максимум 50 за страницу с флагом
has_next, FBO — максимум 1000, конец определяется по неполной странице.
Оба метода требуют RFC3339-таймстемп в filter.since/to (несмотря на то что
кое-где в документации заявлен формат YYYY-MM-DD — на практике это не
принимается, проверено).
"""

import time
from datetime import date, datetime, timedelta

import requests

FBS_URL = "https://api-seller.ozon.ru/v3/posting/fbs/list"
FBO_URL = "https://api-seller.ozon.ru/v2/posting/fbo/list"
FBS_LIMIT = 50
FBO_LIMIT = 1000
MAX_RETRIES = 6


def _iso(d: date, end_of_day: bool = False) -> str:
    t = "23:59:59.999" if end_of_day else "00:00:00.000"
    return f"{d.isoformat()}T{t}Z"


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


def list_fbs_postings(client_id: str, api_key: str, date_from: date, date_to: date, log=print):
    """Генератор словарей {posting_number, order_id, status, created_at} по FBS-отправлениям за период."""
    headers = {"Client-Id": client_id, "Api-Key": api_key, "Content-Type": "application/json"}
    offset = 0
    while True:
        payload = {
            "filter": {"since": _iso(date_from), "to": _iso(date_to, end_of_day=True), "status": ""},
            "limit": FBS_LIMIT,
            "offset": offset,
            "with": {"financial_data": False},
        }
        body = _post_with_retry(FBS_URL, payload, headers)
        result = body.get("result", {})
        postings = result.get("postings", [])
        log(f"    FBS offset={offset}: {len(postings)} отправлений")
        for p in postings:
            yield {
                "posting_number": p["posting_number"],
                "order_id": p.get("order_id", 0),
                "status": p.get("status", ""),
                "created_at": p.get("in_process_at") or p.get("shipment_date"),
            }
        if not result.get("has_next"):
            break
        offset += FBS_LIMIT


def list_fbo_postings(client_id: str, api_key: str, date_from: date, date_to: date, log=print):
    """Генератор словарей {posting_number, order_id, status, created_at} по FBO-отправлениям за период."""
    headers = {"Client-Id": client_id, "Api-Key": api_key, "Content-Type": "application/json"}
    offset = 0
    while True:
        payload = {
            "filter": {"since": _iso(date_from), "to": _iso(date_to, end_of_day=True), "status": ""},
            "limit": FBO_LIMIT,
            "offset": offset,
            "with": {"financial_data": False, "analytics_data": False},
        }
        body = _post_with_retry(FBO_URL, payload, headers)
        postings = body.get("result", [])
        log(f"    FBO offset={offset}: {len(postings)} отправлений")
        for p in postings:
            yield {
                "posting_number": p["posting_number"],
                "order_id": p.get("order_id", 0),
                "status": p.get("status", ""),
                "created_at": p.get("created_at"),
            }
        if len(postings) < FBO_LIMIT:
            break
        offset += FBO_LIMIT


def _parse_dt(value):
    if not value:
        return None
    return datetime.strptime(value[:19], "%Y-%m-%dT%H:%M:%S")


POSTING_COLUMNS = ["cabinet", "scheme", "posting_number", "order_id", "status", "created_at", "source_month"]


def list_all_postings(client_id: str, api_key: str, cabinet: str, year: int, month: int, log=print,
                       lookback_days: int = 90) -> list[dict]:
    """Список FBS+FBO отправлений, СОЗДАННЫХ в окне [начало месяца - lookback_days; конец месяца],
    с дедупом по posting_number (на случай пересечения схем).

    Список ищем по дате СОЗДАНИЯ отправления (это единственное, что принимает фильтр since/to
    у /v3/posting/fbs/list и /v2/posting/fbo/list — проверено эмпирически, по факту фильтрует
    именно created_at, не дату доставки/закрытия). Но отчётный период для денег — всегда
    accrual_date конкретной строки начисления (см. ozon_accrual_core.ingest_month), НЕ дата
    создания отправления: начисление может быть датировано позже создания (лаг доставки,
    а для возвратов/споров — недели-месяцы). lookback_days=90 назад покрывает ~99.8% суммы
    по деньгам (проверено на CloudSix за январь 2026: 99.6% лага <=30 дней, ещё 0.3% в 31-90,
    остаток за пределами 90 дней — тысячные доли процента)."""
    month_start = date(year, month, 1)
    month_end = (date(year + 1, 1, 1) if month == 12 else date(year, month + 1, 1)) - timedelta(days=1)
    search_start = month_start - timedelta(days=lookback_days)

    # У FBO-листинга есть потолок пагинации (offset > ~20000 -> 400 MAX_OFFSET_EXCEEDED,
    # проверено эмпирически) — при широком окне (месяц + 90 дней назад) у активного кабинета
    # это легко превышается одним запросом. Дробим окно на календарные месяцы, чтобы каждый
    # под-запрос оставался в безопасных пределах пагинации независимо от объёма кабинета.
    chunks = []
    chunk_start = search_start
    while chunk_start <= month_end:
        chunk_month_end = (date(chunk_start.year + 1, 1, 1) if chunk_start.month == 12
                            else date(chunk_start.year, chunk_start.month + 1, 1)) - timedelta(days=1)
        chunk_end = min(chunk_month_end, month_end)
        chunks.append((chunk_start, chunk_end))
        chunk_start = chunk_end + timedelta(days=1)

    seen = {}
    for scheme, fn in (("fbs", list_fbs_postings), ("fbo", list_fbo_postings)):
        log(f"  {scheme.upper()} отправления, созданные {search_start}..{month_end} (окно для {year}-{month:02d}), "
            f"{len(chunks)} под-запрос(ов) по месяцу...")
        for c_start, c_end in chunks:
            for p in fn(client_id, api_key, c_start, c_end, log=log):
                seen[p["posting_number"]] = {
                    "cabinet": cabinet,
                    "scheme": scheme,
                    "posting_number": p["posting_number"],
                    "order_id": p["order_id"],
                    "status": p["status"],
                    "created_at": _parse_dt(p["created_at"]) or datetime(year, month, 1),
                    "source_month": month_start,
                }
    return list(seen.values())
