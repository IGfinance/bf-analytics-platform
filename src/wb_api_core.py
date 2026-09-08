#!/usr/bin/env python3
"""
Загрузка отчёта о реализации WB через Statistics API
(v5/supplier/reportDetailByPeriod) напрямую в ClickHouse — источник
данных, альтернативный ручной выгрузке .xlsx (см. wb_core.py). Метод
отдаёт только уже сформированные строки отчёта о реализации (закрытые
операции) — открытых/незакрытых продаж в нём нет, доп. фильтрации по
статусу не требуется.

У метода жёсткий rate-limit (у WB он периодически меняется, поэтому не
хардкодим предположение — просто ретраим на HTTP 429 с честным ожиданием
по Retry-After, если он есть, иначе растущей паузой).

Пагинация — курсором rrdid (rrd_id последней строки предыдущей страницы,
0 для первой страницы), НЕ по датам внутри диапазона: один диапазон
dateFrom/dateTo отдаётся книга за книгой, пока сервер не вернёт пустой
список.
"""

import os
import time
from datetime import date, datetime

import clickhouse_connect
import requests

API_URL = "https://statistics-api.wildberries.ru/api/v5/supplier/reportDetailByPeriod"
PAGE_LIMIT = 100_000
MAX_RETRIES = 15
DEFAULT_RETRY_WAIT = 65

# Поля, которые кладём в отдельные колонки (см. schema_wb_api.sql).
# Всё, что API вернёт сверх этого списка, уходит в extra_fields.
KNOWN_FIELDS = {
    "realizationreport_id", "date_from", "date_to", "create_dt", "currency_name",
    "suppliercontract_code", "gi_id", "dlv_prc", "fix_tariff_date_from", "fix_tariff_date_to",
    "subject_name", "nm_id", "brand_name", "sa_name", "ts_name", "barcode", "doc_type_name",
    "quantity", "retail_price", "retail_amount", "sale_percent", "commission_percent",
    "office_name", "supplier_oper_name", "order_dt", "sale_dt", "rr_dt", "shk_id",
    "retail_price_withdisc_rub", "delivery_amount", "return_amount", "delivery_rub",
    "gi_box_type_name", "product_discount_for_report", "supplier_promo", "ppvz_spp_prc",
    "ppvz_kvw_prc_base", "ppvz_kvw_prc", "sup_rating_prc_up", "is_kgvp_v2",
    "ppvz_sales_commission", "ppvz_for_pay", "ppvz_reward", "acquiring_fee", "acquiring_percent",
    "payment_processing", "acquiring_bank", "ppvz_vw", "ppvz_vw_nds", "ppvz_office_name",
    "ppvz_office_id", "ppvz_supplier_id", "ppvz_supplier_name", "ppvz_inn",
    "declaration_number", "bonus_type_name", "sticker_id", "site_country", "srv_dbs",
    "penalty", "additional_payment", "rebill_logistic_cost", "storage_fee", "deduction",
    "acceptance", "assembly_id", "srid", "report_type", "is_legal_entity", "trbx_id",
    "installment_cofinancing_amount", "wibes_wb_discount_percent", "cashback_amount",
    "cashback_discount", "cashback_commission_change", "order_uid", "payment_schedule",
    "delivery_method",
}

DATE_FIELDS = {"date_from", "date_to", "create_dt", "rr_dt"}
DATETIME_FIELDS = {"fix_tariff_date_from", "fix_tariff_date_to", "order_dt", "sale_dt"}
INT_FIELDS = {
    "realizationreport_id", "gi_id", "nm_id", "shk_id", "ppvz_office_id", "ppvz_supplier_id",
    "assembly_id", "report_type", "payment_schedule", "quantity", "delivery_amount", "return_amount",
}
BOOL_FIELDS = {"srv_dbs", "is_legal_entity"}


def _coerce(field, value):
    if value in (None, ""):
        return None
    if field in DATE_FIELDS:
        try:
            return datetime.strptime(value[:10], "%Y-%m-%d").date()
        except (ValueError, TypeError):
            return None
    if field in DATETIME_FIELDS:
        try:
            return datetime.strptime(value.replace("Z", "").split(".")[0].split("+")[0], "%Y-%m-%dT%H:%M:%S")
        except (ValueError, TypeError, AttributeError):
            return None
    if field in INT_FIELDS:
        try:
            return int(value)
        except (ValueError, TypeError):
            return None
    if field in BOOL_FIELDS:
        return 1 if value else 0
    return value


def _rate_limit_wait_seconds(resp, default: float) -> float:
    """X-Ratelimit-Retry/-Reset у WB — секунды (проверено эмпирически: два
    замера с разницей 9463с в реальном времени показали ровно такую же
    разницу в заголовке — значит это честный таймер до фиксированного
    момента, без домыслов про миллисекунды).

    ВАЖНО: если значение больше пары минут — это не обычный 1-req/min
    лимит (у него Retry ~60с), а какая-то более серьёзная блокировка
    (у нас однажды словили ~16 дней после одного запроса с limit=100000
    на почти годовой диапазон — см. историю чата/памятку по инциденту).
    В этом случае ждать смысла нет: поднимаем исключение, чтобы вызывающий
    код не завис на много часов в цикле ретраев."""
    raw = resp.headers.get("X-Ratelimit-Retry") or resp.headers.get("Retry-After")
    if raw is None:
        return default
    try:
        value = float(raw)
    except ValueError:
        return default
    if value > 300:  # обычный 1-req/min лимит ждёт секунды, не минуты
        raise RuntimeError(
            f"WB API: X-Ratelimit-Retry={value:.0f}с — это не обычный лимит "
            f"(ожидались бы секунды/десятки секунд). Похоже на длительную "
            f"блокировку метода, а не rate-limit — ждать в цикле бессмысленно."
        )
    return value + 2.0  # небольшой запас


def _request_page(token: str, date_from: str, date_to: str, rrdid: int, log=print) -> list:
    params = {"dateFrom": date_from, "dateTo": date_to, "limit": PAGE_LIMIT, "rrdid": rrdid}
    headers = {"Authorization": token}

    for attempt in range(MAX_RETRIES):
        resp = requests.get(API_URL, params=params, headers=headers, timeout=120)
        if resp.status_code == 429:
            wait = _rate_limit_wait_seconds(resp, DEFAULT_RETRY_WAIT)
            log(f"    429 (rate limit), жду {wait:.0f}с (попытка {attempt + 1}/{MAX_RETRIES})")
            time.sleep(wait)
            continue
        resp.raise_for_status()
        return resp.json() or []
    raise RuntimeError(f"WB API: не удалось получить страницу (rrdid={rrdid}) после {MAX_RETRIES} попыток (429)")


def fetch_pages(token: str, date_from: str, date_to: str, log=print):
    """Генератор страниц (списков сырых строк) за период [date_from, date_to] (YYYY-MM-DD).

    Отдаёт по странице сразу после получения (а не всё одним списком в конце) —
    и чтобы не буферить сотни тысяч строк в памяти на многочасовой пагинации,
    и чтобы вызывающий код мог сразу писать каждую страницу в ClickHouse и не
    терять уже полученные данные, если процесс прервётся на следующей странице."""
    rrdid = 0
    while True:
        page = _request_page(token, date_from, date_to, rrdid, log=log)
        log(f"    WB API: страница с rrdid={rrdid}, строк: {len(page)}")
        if not page:
            break
        yield page
        rrdid = page[-1]["rrd_id"]
        if len(page) < PAGE_LIMIT:
            break


def row_to_record(raw: dict, cabinet: str, date_from: date, date_to: date) -> dict:
    record = {"cabinet": cabinet, "source_date_from": date_from, "source_date_to": date_to}
    extra = {}
    for key, value in raw.items():
        if key == "rrd_id":
            record["rrd_id"] = int(value)
        elif key in KNOWN_FIELDS:
            record[key] = _coerce(key, value)
        else:
            if value is not None:
                extra[key] = str(value)
    record["extra_fields"] = extra
    return record


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


ROW_COLUMNS = (
    ["cabinet", "rrd_id"] + sorted(KNOWN_FIELDS) + ["extra_fields", "source_date_from", "source_date_to"]
)


def ingest_period(cabinet: str, date_from: date, date_to: date, log=print) -> dict:
    token = os.environ["WILDBERRIES_API"]
    client = get_client()

    total = 0
    for page in fetch_pages(token, date_from.isoformat(), date_to.isoformat(), log=log):
        records = [row_to_record(raw, cabinet, date_from, date_to) for raw in page]
        data = [[row.get(col) for col in ROW_COLUMNS] for row in records]
        client.insert("wb_api_realization", data, column_names=ROW_COLUMNS)
        total += len(data)
        log(f"  Загружено {len(data)} строк в wb_api_realization (всего: {total}).")

    if total == 0:
        log("  WB API: строк за период не найдено.")
    return {"rows": total}
