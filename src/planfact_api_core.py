"""
Выгрузка операций ПланФакта через API в planfact_operations_api.

API не умеет фильтровать по дате правки (неизвестные фильтры молча
игнорируются, проверено 2026-10-01), поэтому история обновляется так:
каждый прогон перетягивает ВСЁ окно дат целиком (~1000 операций на запрос,
год ≈ 24 запроса) и перезаписывает строки (ReplacingMergeTree по loaded_at).
Операции, которые были в окне раньше, а теперь не пришли (удалены в
ПланФакте), помечаются is_deleted = 1.
"""

import os
import time
from datetime import date, datetime, timezone

import clickhouse_connect
import ch_connect
import requests

BASE_URL = "https://api.planfact.io/api/v1/operations"
PAGE = 1000

COLUMNS = [
    "operation_id", "part_id", "operation_date", "calculation_date", "operation_type",
    "is_move", "is_committed", "company_id", "company_title", "account_id",
    "account_title", "currency", "contragent_id", "contragent_title", "category_id",
    "category_title", "category_type", "activity_type", "pf_project_id", "pf_project",
    "part_value", "amount", "operation_value", "comment", "create_date", "modify_date",
    "is_deleted", "loaded_at",
]


def get_client():
    return ch_connect.get_client(
        host=os.environ["CLICKHOUSE_HOST"],
        port=int(os.environ.get("CLICKHOUSE_PORT", "8443")),
        username=os.environ.get("CLICKHOUSE_USER", "default"),
        password=os.environ.get("CLICKHOUSE_PASSWORD", ""),
        database=os.environ.get("CLICKHOUSE_DATABASE", "default"),
        secure=os.environ.get("CLICKHOUSE_SECURE", "1") != "0",
    )


def fetch_operations(api_key: str, date_from: str, date_to: str, delay: float = 1.0) -> list[dict]:
    """Все операции с operationDate в [date_from, date_to], постранично."""
    headers = {"X-ApiKey": api_key}
    items: list[dict] = []
    offset = 0
    while True:
        params = {
            "filter.operationDateStart": date_from,
            "filter.operationDateEnd": date_to,
            "paging.limit": PAGE,
            "paging.offset": offset,
        }
        for attempt in range(6):
            r = requests.get(BASE_URL, headers=headers, params=params, timeout=60)
            if r.status_code in (429, 500, 502, 503, 504):
                time.sleep(5 * (attempt + 1))
                continue
            r.raise_for_status()
            break
        else:
            raise RuntimeError(f"ПланФакт: не удалось получить offset={offset}, последний статус {r.status_code}")
        body = r.json()
        if not body.get("isSuccess", True):
            raise RuntimeError(f"ПланФакт: {body.get('errorMessage')}")
        page = body["data"]["items"]
        items.extend(page)
        if len(page) < PAGE:
            return items
        offset += len(page)
        time.sleep(delay)


def _d(s):
    return date.fromisoformat(s[:10]) if s else None


def _dt(s):
    if not s or s.startswith("0001"):
        return None
    return datetime.fromisoformat(s[:19])


def _nz(v):
    """id 0 в ответе ПланФакта означает «нет»."""
    return v if v else None


def flatten(op: dict, loaded_at: datetime) -> list[list]:
    """Операция → строки по частям (без частей — одна строка с part_id = 0)."""
    sign = 1 if op["operationType"] == "Income" else -1
    is_move = 1 if (op.get("boundMoveOperationId") or op.get("boundMoveOperation")) else 0
    acc = op.get("account") or {}
    comp = op.get("accountCompany") or {}
    cur = (op.get("accountCurrency") or {}).get("currencyCode") or acc.get("currencyCode") or ""
    parts = op.get("operationParts") or [None]
    rows = []
    for p in parts:
        if p is None:
            src, ca, cat, proj, pid = op, op.get("contrAgent"), op.get("operationCategory") or {}, None, 0
            part_value, calc = op["value"], _d(op.get("calculationPeriodDate"))
            activity = op.get("operationCategoryActivityType")
        else:
            ca, cat, proj, pid = p.get("contrAgent"), p.get("operationCategory") or {}, p.get("project"), p["operationPartId"]
            part_value, calc = p["value"], _d(p.get("calculationDate"))
            activity = p.get("operationCategoryActivityType")
        rows.append([
            op["operationId"], pid, _d(op["operationDate"]), calc, op["operationType"],
            is_move, 1 if op.get("isCommitted") else 0,
            comp.get("companyId") or acc.get("companyId") or 0, comp.get("title") or "",
            acc.get("accountId") or 0, acc.get("title") or "", cur,
            _nz((ca or {}).get("contrAgentId")), (ca or {}).get("title"),
            _nz(cat.get("operationCategoryId")), cat.get("title"), cat.get("operationCategoryType"),
            activity,
            _nz((proj or {}).get("projectId")), (proj or {}).get("title"),
            part_value, sign * part_value, op["value"], op.get("comment") or "",
            _dt(op.get("createDate")), _dt(op.get("modifyDate")),
            0, loaded_at,
        ])
    return rows


def tombstone_missing(client, date_from: str, date_to: str, run_ts: datetime,
                      max_share: float = 0.2, force: bool = False) -> int:
    """Пометить is_deleted = 1 то, что в окне есть в таблице, но не пришло в этом прогоне
    (у пришедших loaded_at = run_ts). Защита: больше max_share окна за раз — отказ."""
    where = ("operation_date BETWEEN {f:Date} AND {t:Date} AND is_deleted = 0 AND loaded_at < toDateTime({r:UInt32})")
    # Типизированные серверные параметры, метка — epoch (см. sync).
    params = {"f": date_from, "t": date_to, "r": int(run_ts.timestamp())}
    missing = client.query(f"SELECT count() FROM planfact_operations_api FINAL WHERE {where}", parameters=params).result_rows[0][0]
    total = client.query(
        "SELECT count() FROM planfact_operations_api FINAL WHERE operation_date BETWEEN {f:Date} AND {t:Date} AND is_deleted = 0",
        parameters=params).result_rows[0][0]
    if not missing:
        return 0
    if not force and total and missing / total > max_share:
        raise RuntimeError(f"Отказ: {missing} из {total} строк окна пропали из выгрузки (> {max_share:.0%}) — "
                           "похоже на сбой API, а не на удаления. Проверьте и запустите с --force-delete.")
    cols = ", ".join(c for c in COLUMNS if c not in ("is_deleted", "loaded_at"))
    client.command(
        f"INSERT INTO planfact_operations_api ({cols}, is_deleted, loaded_at) "
        f"SELECT {cols}, 1, now() FROM planfact_operations_api FINAL WHERE {where}", parameters=params)
    return missing


def sync(client, api_key: str, date_from: str, date_to: str, force_delete: bool = False,
         dry_run: bool = False) -> dict:
    # Метку прогона берём у сервера ClickHouse как epoch и делаем tz-aware: naive datetime
    # clickhouse_connect трактует в локальном поясе машины, и сравнение «пришло в этом
    # прогоне» (loaded_at < run_ts) в SQL уезжает на смещение пояса.
    epoch = int(datetime.now().timestamp()) if dry_run else client.query("SELECT toUnixTimestamp(now())").result_rows[0][0]
    run_ts = datetime.fromtimestamp(epoch, timezone.utc)
    ops = fetch_operations(api_key, date_from, date_to)
    rows = [r for op in ops for r in flatten(op, run_ts)]
    summary = {"operations": len(ops), "rows": len(rows), "deleted": 0}
    if dry_run:
        return summary
    if not ops:
        raise RuntimeError("ПланФакт вернул 0 операций за окно — не пишу и не удаляю (похоже на сбой).")
    client.insert("planfact_operations_api", rows, column_names=COLUMNS)
    summary["deleted"] = tombstone_missing(client, date_from, date_to, run_ts, force=force_delete)
    return summary
