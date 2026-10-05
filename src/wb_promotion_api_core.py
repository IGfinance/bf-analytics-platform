"""Загрузка расходов на продвижение WB из рекламного API в wb_promotion_api.

Метод GET https://advert-api.wildberries.ru/adv/v1/upd?from=&to= — история
списаний (campName, advertId, updNum, updTime, updSum, paymentType…). Окно не
больше 31 дня, поэтому период режется на чанки. Лимит метода — 5 запросов,
запас большой, но пауза между запросами держится (429 → ждём и повторяем).
Токен — из cabinet_credentials.get_wb_token (тот же, что у финансового API;
нужна категория «Продвижение»).

Идемпотентно: ключ ReplacingMergeTree естественный (см. schema_wb_promotion_api.sql).
"""

from __future__ import annotations

import re
import time
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

import requests

from cabinet_credentials import get_wb_token
from wb_api_core import get_client

BASE_URL = "https://advert-api.wildberries.ru"
CHUNK_DAYS = 31
PAUSE_SECONDS = 1.5
MAX_RETRIES = 5
MSK = ZoneInfo("Europe/Moscow")

COLUMNS = ["cabinet", "advert_id", "upd_num", "upd_time", "promo_date", "camp_name",
           "advert_type", "advert_status", "payment_type", "upd_sum", "currency", "loaded_at"]


def chunks(date_from: date, date_to: date, size: int = CHUNK_DAYS):
    """Непересекающиеся окна [from, to] не длиннее size дней."""
    cur = date_from
    while cur <= date_to:
        end = min(cur + timedelta(days=size - 1), date_to)
        yield cur, end
        cur = end + timedelta(days=1)


def parse_ts(value: str) -> datetime:
    """ISO-время WB → aware datetime. Дробная часть бывает 5 знаков ('.95896+03:00'),
    а fromisoformat в Python 3.9 принимает только 3 или 6 — дробную часть отбрасываем
    (секунд хватает: ключ строки включает номер документа)."""
    return datetime.fromisoformat(re.sub(r"\.\d+", "", value))


def to_record(raw: dict, cabinet: str, loaded_at: datetime) -> list:
    """Строка API → строка таблицы. Время приводится к МСК, дата — по МСК."""
    ts = parse_ts(raw["updTime"]).astimezone(MSK)
    return [
        cabinet, int(raw["advertId"]), int(raw["updNum"]),
        ts.replace(tzinfo=None), ts.date(), raw.get("campName") or "",
        raw.get("advertType"), raw.get("advertStatus"), raw.get("paymentType") or "",
        float(raw["updSum"]), raw.get("currency") or "RUB", loaded_at,
    ]


def fetch_upd(token: str, date_from: date, date_to: date, log=print) -> list[dict]:
    params = {"from": date_from.isoformat(), "to": date_to.isoformat()}
    for attempt in range(MAX_RETRIES):
        resp = requests.get(f"{BASE_URL}/adv/v1/upd", headers={"Authorization": token},
                            params=params, timeout=120)
        if resp.status_code == 429:
            wait = float(resp.headers.get("X-Ratelimit-Retry") or resp.headers.get("Retry-After") or 10)
            log(f"    429, жду {wait:.0f}с (попытка {attempt + 1}/{MAX_RETRIES})")
            time.sleep(wait)
            continue
        resp.raise_for_status()
        return resp.json() or []
    raise RuntimeError(f"WB рекламное API: /adv/v1/upd не ответил за {MAX_RETRIES} попыток (429)")


def ingest_period(cabinet: str, date_from: date, date_to: date, log=print,
                  database: str | None = None, dry_run: bool = False) -> dict:
    token = get_wb_token(cabinet)
    client = None if dry_run else get_client(database=database)
    loaded_at = datetime.now().replace(microsecond=0)
    total_rows, total_sum = 0, 0.0
    for start, end in chunks(date_from, date_to):
        raw_rows = fetch_upd(token, start, end, log=log)
        data = [to_record(r, cabinet, loaded_at) for r in raw_rows]
        s = sum(r[9] for r in data)
        log(f"  {cabinet} {start}..{end}: {len(data)} строк, {s:,.0f} ₽")
        if data and client is not None:
            client.insert("wb_promotion_api", data, column_names=COLUMNS)
        total_rows += len(data)
        total_sum += s
        time.sleep(PAUSE_SECONDS)
    return {"rows": total_rows, "sum": total_sum}
