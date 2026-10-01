#!/usr/bin/env python3
"""
Загрузка отчёта о реализации WB через ФИНАНСОВОЕ API напрямую в ClickHouse —
источник данных, альтернативный ручной выгрузке .xlsx (см. wb_core.py для
детальных отчётов и wb_summary_core.py для сводных).

ПЕРЕПИСАНО 2026-09-27. Раньше модуль работал с методом Statistics API
`GET /api/v5/supplier/reportDetailByPeriod`. WB его отключил — метод отдаёт
HTTP 404 "This method is deprecated". Подробности, история вопроса и
обоснование имён колонок/типов — в шапке schema_wb_api.sql, здесь не
дублируем.

Путь загрузки: list → detailed/{reportId}.
  1. `list` за период отдаёт перечень отчётов (reportId + итоговые суммы по
     каждому) — пишем в wb_api_report_summary.
  2. для каждого reportId `detailed/{reportId}` отдаёт строки, страницами,
     курсор — rrdId последней строки предыдущей страницы (проверено:
     rrdId=<последний> возвращает строки со следующего id).
Так строки сразу привязаны к конкретному отчёту, как в .xlsx, и не нужно
угадывать семантику диапазона дат у `detailed` без reportId.

ЛИМИТ 1 запрос в минуту (X-Ratelimit-Limit: 1). Между запросами модуль сам
держит паузу MIN_REQUEST_INTERVAL — без неё каждый второй запрос гарантированно
уходит в 429. Загрузка года по одному кабинету — это часы, это нормально.
"""

# Аннотации вида `list | dict` и `str | None` требуют Python 3.10+, а тесты
# этого модуля должны собираться и на 3.9 (venv проекта на 3.13, но на машинах
# разработки встречается системный 3.9 — на нём уже не собираются
# test_ingest_card.py и test_webapp_sources.py, см. их импорты wb_core).
# Отложенные аннотации снимают проблему, ничего не меняя в рантайме.
from __future__ import annotations

import os
import re
import time
from datetime import date, datetime

import clickhouse_connect
import ch_connect
import requests

from cabinet_credentials import get_wb_token

HOST = "https://finance-api.wildberries.ru"
LIST_PATH = "/api/finance/v1/sales-reports/list"
DETAILED_PATH = "/api/finance/v1/sales-reports/detailed/{report_id}"

# Ровно то, что разрешает X-Ratelimit-Limit, плюс запас: лимит считается
# сервером по своим часам, и запрос "точно через 60с" стабильно ловит 429.
MIN_REQUEST_INTERVAL = 65.0
PAGE_LIMIT = 10_000
MAX_RETRIES = 10
DEFAULT_RETRY_WAIT = 65.0
# Больше этого — не обычный rate-limit, а длительная блокировка метода
# (в сентябре 2026 уже ловили ~16 дней после одного тяжёлого запроса).
# Ждать в цикле бессмысленно, поднимаем исключение.
LONG_BLOCK_THRESHOLD = 300.0

DATE, DATETIME, INT, FLOAT, BOOL, STR = "date", "datetime", "int", "float", "bool", "str"

# Единый источник правды по типам полей detailed. Имена — snake_case,
# camelCase из API приводится camel_to_snake(). Состав сверяется с
# schema_wb_api.sql тестом tests/test_wb_api_schema.py — если WB добавит
# поле, тест не упадёт (поле уйдёт в extra_fields), а вот расхождение между
# этим словарём и SQL-схемой он поймает.
DETAILED_FIELDS = {
    "report_id": INT, "report_type": INT, "date_from": DATE, "date_to": DATE,
    "create_date": DATE, "currency": STR,
    "rrd_id": INT,
    "subject_name": STR, "nm_id": INT, "brand_name": STR, "vendor_code": STR,
    "title": STR, "tech_size": STR, "sku": STR,
    "doc_type_name": STR, "seller_oper_name": STR, "quantity": INT,
    "order_dt": DATETIME, "sale_dt": DATETIME, "rr_date": DATE,
    "shk_id": INT, "order_id": INT, "order_uid": STR, "srid": STR,
    "retail_price": FLOAT, "retail_amount": FLOAT, "retail_price_with_disc": FLOAT,
    "for_pay": FLOAT, "ppvz_sales_commission": FLOAT, "ppvz_reward": FLOAT,
    "acquiring_fee": FLOAT, "vw": FLOAT, "vw_nds": FLOAT,
    "delivery_service": FLOAT, "penalty": FLOAT, "additional_payment": FLOAT,
    "rebill_logistic_cost": FLOAT, "rebill_logistic_org": STR,
    "paid_storage": FLOAT, "deduction": FLOAT, "paid_acceptance": FLOAT,
    "installment_cofinancing_amount": FLOAT, "cashback_amount": FLOAT,
    "cashback_discount": FLOAT, "cashback_commission_change": FLOAT,
    "sale_percent": FLOAT, "commission_percent": FLOAT, "dlv_prc": FLOAT,
    "spp": FLOAT, "kvw_base": FLOAT, "kvw": FLOAT, "sup_rating_up": FLOAT,
    "is_kgvp_v2": FLOAT, "acquiring_percent": FLOAT,
    "product_discount_for_report": FLOAT, "seller_promo": FLOAT,
    "wibes_discount_percent": FLOAT, "warehouse_logistics_coeff": FLOAT,
    "seller_promo_id": INT, "seller_promo_discount": FLOAT,
    "loyalty_id": INT, "loyalty_discount": FLOAT,
    "uuid_promocode": STR, "sale_price_promocode_discount_prc": FLOAT,
    "article_substitution": STR, "sale_price_affiliated_discount_prc": FLOAT,
    "sale_price_wholesale_discount_prc": FLOAT,
    "delivery_amount": INT, "return_amount": INT, "delivery_method": STR,
    "office_name": STR, "gi_id": INT, "gi_box_type_name": STR,
    "fix_tariff_date_from": DATETIME, "fix_tariff_date_to": DATETIME,
    "ppvz_office_name": STR, "ppvz_office_id": INT,
    "ppvz_supplier_name": STR, "ppvz_supplier_inn": STR,
    "trbx_id": STR, "sticker_id": STR, "country": STR,
    "declaration_number": STR, "bonus_type_name": STR,
    "payment_processing": STR, "acquiring_bank": STR, "payment_schedule": FLOAT,
    "srv_dbs": BOOL, "is_b2b": BOOL, "paid_with_social_certificate": BOOL,
    "b2b_customer_tin": STR,
}

SUMMARY_FIELDS = {
    "report_id": INT, "report_type": INT, "seller_finance_name": STR,
    "date_from": DATE, "date_to": DATE, "create_date": DATE, "currency": STR,
    "retail_amount_sum": FLOAT, "for_pay_sum": FLOAT, "avg_sale_percent": FLOAT,
    "delivery_service_sum": FLOAT, "paid_storage_sum": FLOAT,
    "paid_acceptance_sum": FLOAT, "deduction_sum": FLOAT, "penalty_sum": FLOAT,
    "additional_payment_sum": FLOAT, "cashback_amount_sum": FLOAT,
    "cashback_discount_sum": FLOAT, "cashback_commission_change_sum": FLOAT,
    "payment_schedule": FLOAT, "bank_payment_sum": FLOAT,
}

DETAILED_COLUMNS = ["cabinet"] + sorted(DETAILED_FIELDS) + ["extra_fields"]
SUMMARY_COLUMNS = ["cabinet"] + sorted(SUMMARY_FIELDS) + ["extra_fields"]

_CAMEL_1 = re.compile(r"(?<=[a-z0-9])([A-Z])")
_CAMEL_2 = re.compile(r"(?<=[A-Z])([A-Z][a-z])")


def camel_to_snake(name: str) -> str:
    """rrdId -> rrd_id, forPay -> for_pay, isKgvpV2 -> is_kgvp_v2.

    Два правила вместо одного: первое рвёт границу строчная→прописная,
    второе — конец аббревиатуры перед новым словом (ABCDef -> abc_def).
    """
    return _CAMEL_2.sub(r"_\1", _CAMEL_1.sub(r"_\1", name)).lower()


def coerce(kind: str, value):
    """Приведение значения из JSON к типу колонки ClickHouse.

    Пустая строка трактуется как NULL, а не как 0/'': WB отдаёт "" и для
    незаполненных дат ("fixTariffDateFrom": ""), и для незаполненных строк.
    Для денег важно, что они приходят СТРОКАМИ ("3058674.41") — их надо
    именно парсить, молча положить в Float64 не получится.
    """
    if value is None or value == "":
        return None
    if kind is STR:
        return str(value)
    if kind is BOOL:
        if isinstance(value, str):
            return 1 if value.lower() in ("true", "1", "yes") else 0
        return 1 if value else 0
    if kind is DATE:
        try:
            return datetime.strptime(str(value)[:10], "%Y-%m-%d").date()
        except (ValueError, TypeError):
            return None
    if kind is DATETIME:
        raw = str(value).replace("Z", "").split(".")[0].split("+")[0]
        try:
            return datetime.strptime(raw, "%Y-%m-%dT%H:%M:%S")
        except (ValueError, TypeError):
            try:
                return datetime.strptime(raw[:10], "%Y-%m-%d")
            except (ValueError, TypeError):
                return None
    if kind is INT:
        try:
            return int(float(value))
        except (ValueError, TypeError):
            return None
    if kind is FLOAT:
        try:
            return float(value)
        except (ValueError, TypeError):
            return None
    return str(value)


def raw_to_record(raw: dict, cabinet: str, spec: dict) -> tuple[dict, list[str]]:
    """Возвращает (запись, список полей, не попавших в spec).

    Неизвестные поля НЕ отбрасываются: они уходят в extra_fields и попадают
    в лог, чтобы добавленное WB поле было видно, а не потеряно молча.
    """
    record = {"cabinet": cabinet}
    extra, unmapped = {}, []
    for key, value in raw.items():
        col = camel_to_snake(key)
        kind = spec.get(col)
        if kind is None:
            unmapped.append(key)
            if value not in (None, ""):
                extra[key] = str(value)
        else:
            record[col] = coerce(kind, value)
    record["extra_fields"] = extra
    return record, unmapped


class _Pacer:
    """Держит паузу между запросами под лимит 1 req/min."""

    def __init__(self, interval: float = MIN_REQUEST_INTERVAL, log=print):
        self.interval = interval
        self.log = log
        self._last = 0.0

    def wait(self):
        if self._last:
            left = self.interval - (time.monotonic() - self._last)
            if left > 0:
                self.log(f"    пауза {left:.0f}с под лимит 1 запрос/мин")
                time.sleep(left)
        self._last = time.monotonic()


def _retry_wait(resp, default: float) -> float:
    raw = resp.headers.get("X-Ratelimit-Retry") or resp.headers.get("Retry-After")
    try:
        value = float(raw) if raw is not None else default
    except ValueError:
        value = default
    if value > LONG_BLOCK_THRESHOLD:
        raise RuntimeError(
            f"WB API: retry={value:.0f}с — это не обычный лимит (ожидались бы "
            f"секунды/десятки секунд), а длительная блокировка метода. "
            f"Ждать в цикле бессмысленно, прерываемся."
        )
    return value + 2.0


def _post(token: str, path: str, body: dict, pacer: _Pacer, log=print) -> list | dict:
    url = HOST + path
    headers = {"Authorization": token, "Content-Type": "application/json"}
    for attempt in range(MAX_RETRIES):
        pacer.wait()
        resp = requests.post(url, json=body, headers=headers, timeout=180)
        if resp.status_code == 429:
            wait = _retry_wait(resp, DEFAULT_RETRY_WAIT)
            log(f"    429, жду {wait:.0f}с (попытка {attempt + 1}/{MAX_RETRIES})")
            time.sleep(wait)
            continue
        if resp.status_code == 404 and "deprecated" in resp.text.lower():
            raise RuntimeError(
                f"WB API: метод {path} помечен deprecated — WB снова сменил "
                f"контракт. Ответ: {resp.text[:300]}"
            )
        if resp.status_code >= 400:
            raise RuntimeError(f"WB API {resp.status_code} на {path}: {resp.text[:500]}")
        # Период без отчётов: WB отдаёт 200 с ПУСТЫМ телом, а не с "[]".
        # resp.json() на таком падает ValueError, и раньше это выглядело как
        # сбой куска при дозагрузке истории (поймано 2026-09-27 на кабинетах
        # ARB/Feel/NoxLab, у которых до 2025-03 отчётов просто нет).
        if not resp.text.strip():
            return []
        try:
            return resp.json() or []
        except ValueError as e:
            raise RuntimeError(
                f"WB API {path}: ответ 200, но тело не разбирается как JSON "
                f"({e}). Первые 300 символов: {resp.text[:300]!r}"
            ) from e
    raise RuntimeError(f"WB API: {path} не ответил за {MAX_RETRIES} попыток (429)")


INSERT_RETRIES = 6
INSERT_RETRY_WAIT = 20.0


def _insert_with_retry(client_box: dict, table: str, data, columns, database, log=print):
    """INSERT с повтором: обрыв связи с ClickHouse не должен стоить всего куска.

    Ночью 2026-09-27 SSH-туннель к ClickHouse оборвался (машина ушла в сон), и
    дозагрузка 7 часов молотила API впустую — каждая вставка падала, каждый
    кусок помечался неудачным, данные из уже скачанных страниц выбрасывались.
    API-запросы при лимите 1/мин — самый дорогой ресурс здесь, терять их
    из-за секундной недоступности базы нельзя.

    client_box — изменяемая обёртка {'client': ...}: при обрыве соединение
    пересоздаётся, и вызывающий код продолжает работать с новым клиентом.
    """
    last = None
    for attempt in range(INSERT_RETRIES):
        try:
            client_box["client"].insert(table, data, column_names=columns)
            return
        except Exception as e:  # noqa: BLE001 — нас интересует любой сбой связи
            last = e
            wait = INSERT_RETRY_WAIT * (attempt + 1)
            log(f"    ClickHouse недоступен ({str(e)[:120]}), "
                f"повтор {attempt + 1}/{INSERT_RETRIES} через {wait:.0f}с")
            time.sleep(wait)
            try:
                client_box["client"] = get_client(database=database)
            except Exception as e2:  # noqa: BLE001
                log(f"    пересоздать соединение не вышло: {str(e2)[:120]}")
    raise RuntimeError(
        f"ClickHouse недоступен после {INSERT_RETRIES} попыток, последняя ошибка: {last}"
    )


def get_client(database: str | None = None):
    host = os.environ["CLICKHOUSE_HOST"]
    port = int(os.environ.get("CLICKHOUSE_PORT", "8443"))
    user = os.environ.get("CLICKHOUSE_USER", "default")
    password = os.environ.get("CLICKHOUSE_PASSWORD", "")
    if database is None:
        database = os.environ.get("CLICKHOUSE_DATABASE", "default")
    secure = os.environ.get("CLICKHOUSE_SECURE", "1") != "0"
    return ch_connect.get_client(
        host=host, port=port, username=user, password=password,
        database=database, secure=secure,
    )


def _log_unmapped(box, cabinet: str, endpoint: str, report_id: int, fields: set[str], log=print):
    if not fields:
        return
    log(f"    ВНИМАНИЕ: поля вне схемы ({endpoint}): {sorted(fields)} — ушли в extra_fields")
    box["client"].insert(
        "wb_api_unmapped_fields_log",
        [[cabinet, endpoint, report_id, f] for f in sorted(fields)],
        column_names=["cabinet", "endpoint", "report_id", "raw_field"],
    )


def fetch_report_list(token: str, date_from: date, date_to: date,
                      pacer: _Pacer, log=print) -> list[dict]:
    """Метод list: перечень отчётов за период с итоговыми суммами."""
    body = {"dateFrom": date_from.isoformat(), "dateTo": date_to.isoformat()}
    data = _post(token, LIST_PATH, body, pacer, log=log)
    if not isinstance(data, list):
        raise RuntimeError(f"WB API list: ожидался список, пришло {type(data).__name__}: {str(data)[:300]}")
    return data


def fetch_detailed_pages(token: str, report_id: int, pacer: _Pacer, log=print):
    """Генератор страниц строк одного отчёта. Курсор — rrdId последней строки.

    Отдаём страницу сразу, а не копим всё в памяти: на лимите 1 запрос/мин
    загрузка идёт долго, и прерванный процесс не должен терять уже
    полученные страницы.
    """
    cursor = 0
    seen_cursors = set()
    while True:
        body = {"limit": PAGE_LIMIT, "rrdId": cursor}
        page = _post(token, DETAILED_PATH.format(report_id=report_id), body, pacer, log=log)
        if not isinstance(page, list):
            raise RuntimeError(f"WB API detailed: ожидался список, пришло {str(page)[:300]}")
        log(f"    отчёт {report_id}: страница с rrdId={cursor}, строк {len(page)}")
        if not page:
            break
        yield page

        # Курсор — rrdId ПОСЛЕДНЕЙ строки страницы, а не максимальный.
        # Строки в ответе НЕ отсортированы по rrdId: на отчёте 292370717
        # (CloudSix) первая страница шла 2889361109893 … 2889302569525 при
        # max 2889923437304. Курсор от max перепрыгивал через строки —
        # вторая страница начиналась ПОЗЖЕ, чем нужно, и данные терялись
        # молча. Проверено 2026-09-28: с курсором по последней строке
        # страница 2 начинается ровно с cursor+1, пересечение страниц 0 строк,
        # отчёт полностью выбирается за 2 страницы (10000 + 5179).
        # Отсюда же правило: НЕ сортировать и НЕ брать min/max от rrdId —
        # порядок строк задаёт сервер, наше дело его не ломать.
        new_cursor = int(page[-1]["rrdId"])
        if new_cursor == cursor or new_cursor in seen_cursors:
            raise RuntimeError(
                f"WB API detailed: курсор повторяется (rrdId={new_cursor}) — "
                f"прерываемся, чтобы не крутить бесконечный цикл"
            )
        seen_cursors.add(new_cursor)
        cursor = new_cursor
        if len(page) < PAGE_LIMIT:
            break


def ingest_period(cabinet: str, date_from: date, date_to: date, log=print,
                  database: str | None = None, with_detailed: bool = True,
                  pacer: _Pacer | None = None) -> dict:
    """Грузит отчёты WB за период: сводку по каждому отчёту (list) и,
    если with_detailed, все их строки (detailed/{reportId}).

    Идемпотентно: обе таблицы — ReplacingMergeTree (по cabinet+report_id и
    cabinet+rrd_id), повторный прогон того же периода перезапишет строки,
    а не задвоит их.

    pacer — общий ограничитель частоты. Передавайте свой, если вызываете
    функцию несколько раз подряд по ОДНОМУ кабинету (напр. дозагрузка
    истории кусками, scripts/backfill_wb_api.py): свежий pacer на каждый
    вызов считает, что запросов ещё не было, и первый запрос куска уходит
    без паузы — то есть прямо в 429. Для РАЗНЫХ кабинетов общий pacer не
    нужен и вреден: лимит у WB привязан к токену, а не к IP (проверено
    2026-09-27 — два запроса подряд разными токенами оба прошли), так что
    кабинеты грузятся параллельно, каждый со своим pacer.
    """
    token = get_wb_token(cabinet)
    box = {"client": get_client(database=database)}
    if pacer is None:
        pacer = _Pacer(log=log)

    log(f"WB finance API: {cabinet}, период {date_from}..{date_to}")
    reports = fetch_report_list(token, date_from, date_to, pacer, log=log)
    log(f"  Отчётов за период: {len(reports)}")
    if not reports:
        log("  Отчётов нет — грузить нечего.")
        return {"reports": 0, "summary_rows": 0, "detailed_rows": 0}

    summary_records, unmapped_summary = [], set()
    for raw in reports:
        rec, unmapped = raw_to_record(raw, cabinet, SUMMARY_FIELDS)
        summary_records.append(rec)
        unmapped_summary.update(unmapped)
    _insert_with_retry(box, "wb_api_report_summary",
                       [[r.get(c) for c in SUMMARY_COLUMNS] for r in summary_records],
                       SUMMARY_COLUMNS, database, log=log)
    log(f"  Загружено {len(summary_records)} строк в wb_api_report_summary.")
    _log_unmapped(box, cabinet, "list", 0, unmapped_summary, log=log)

    for r in summary_records:
        log(f"    отчёт {r['report_id']} (тип {r.get('report_type')}): "
            f"к перечислению {r.get('for_pay_sum')}, выплата {r.get('bank_payment_sum')}")

    if not with_detailed:
        return {"reports": len(reports), "summary_rows": len(summary_records), "detailed_rows": 0}

    total = 0
    for rec in summary_records:
        report_id = rec["report_id"]
        unmapped_detailed = set()
        for page in fetch_detailed_pages(token, report_id, pacer, log=log):
            records = []
            for raw in page:
                row, unmapped = raw_to_record(raw, cabinet, DETAILED_FIELDS)
                records.append(row)
                unmapped_detailed.update(unmapped)
            _insert_with_retry(box, "wb_api_realization",
                               [[r.get(c) for c in DETAILED_COLUMNS] for r in records],
                               DETAILED_COLUMNS, database, log=log)
            total += len(records)
            log(f"      записано {len(records)} строк (всего {total})")
        _log_unmapped(box, cabinet, "detailed", report_id, unmapped_detailed, log=log)

    log(f"  Итого строк детализации: {total}")
    return {"reports": len(reports), "summary_rows": len(summary_records), "detailed_rows": total}
