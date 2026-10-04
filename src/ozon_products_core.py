"""Каталог товаров Ozon с брендами: /v3/product/list + /v4/product/info/attributes.

Бренд — атрибут карточки с id 85 («Бренд»). Метод атрибутов принимает до 1000
product_id за запрос; список товаров листается по last_id.
"""

import os
import time

import ch_connect
import requests

from cabinet_credentials import get_ozon_credentials

BASE = "https://api-seller.ozon.ru"
BRAND_ATTRIBUTE_ID = 85
PAGE = 1000
MAX_RETRIES = 6


def _post(client_id: str, api_key: str, path: str, payload: dict) -> dict:
    headers = {"Client-Id": client_id, "Api-Key": api_key, "Content-Type": "application/json"}
    delay = 5
    for _ in range(MAX_RETRIES):
        resp = requests.post(BASE + path, json=payload, headers=headers, timeout=60)
        if resp.status_code == 429:
            time.sleep(delay)
            delay = min(delay * 2, 60)
            continue
        resp.raise_for_status()
        return resp.json()
    raise RuntimeError(f"Ozon API {path}: 429 после {MAX_RETRIES} попыток")


def _list_visibility(client_id: str, api_key: str, visibility: str) -> list[dict]:
    items, last_id = [], ""
    while True:
        res = _post(client_id, api_key, "/v3/product/list",
                    {"filter": {"visibility": visibility}, "last_id": last_id, "limit": PAGE})["result"]
        items.extend(res.get("items", []))
        last_id = res.get("last_id", "")
        if not last_id or not res.get("items"):
            return items


def fetch_product_list(client_id: str, api_key: str) -> list[dict]:
    """Все товары кабинета, включая архивные.

    ВАЖНО: visibility=ALL в Ozon НЕ включает архивные товары (Isonic: ALL — 80,
    ARCHIVED — ещё 173), а продажи по снятым с продажи артикулам в отчётах есть.
    Поэтому берём оба набора и объединяем по product_id."""
    by_id: dict[int, dict] = {}
    for visibility in ("ALL", "ARCHIVED"):
        for it in _list_visibility(client_id, api_key, visibility):
            by_id[int(it["product_id"])] = it
    return list(by_id.values())


def fetch_brands(client_id: str, api_key: str, product_ids: list[int]) -> dict[int, tuple[str, str]]:
    """product_id → (название, бренд). Бренд '' если атрибута нет.

    visibility=ALL архивные товары не отдаёт, поэтому недостающие запрашиваем
    повторно с ARCHIVED."""
    out: dict[int, tuple[str, str]] = {}
    for visibility in ("ALL", "ARCHIVED"):
        todo = [p for p in product_ids if p not in out]
        for i in range(0, len(todo), PAGE):
            chunk = [str(p) for p in todo[i:i + PAGE]]
            res = _post(client_id, api_key, "/v4/product/info/attributes",
                        {"filter": {"product_id": chunk, "visibility": visibility}, "limit": PAGE, "last_id": ""})
            for p in res.get("result", []):
                brand = ""
                for a in p.get("attributes", []):
                    if a.get("id") == BRAND_ATTRIBUTE_ID:
                        vals = a.get("values") or []
                        brand = (vals[0].get("value") or "").strip() if vals else ""
                        break
                out[int(p["id"])] = (p.get("name") or "", brand)
    return out


ROW_COLUMNS = ["cabinet", "product_id", "offer_id", "sku", "name", "brand", "archived"]


def collect(cabinet: str) -> list[list]:
    client_id, api_key = get_ozon_credentials(cabinet)
    items = fetch_product_list(client_id, api_key)
    info = fetch_brands(client_id, api_key, [int(i["product_id"]) for i in items])
    rows = []
    for it in items:
        pid = int(it["product_id"])
        name, brand = info.get(pid, ("", ""))
        rows.append([cabinet, pid, it.get("offer_id", ""), int(it.get("sku") or 0), name, brand,
                     1 if it.get("archived") else 0])
    return rows


def get_client():
    return ch_connect.get_client(
        host=os.environ["CLICKHOUSE_HOST"], port=int(os.environ.get("CLICKHOUSE_PORT", "8443")),
        username=os.environ.get("CLICKHOUSE_USER", "default"), password=os.environ.get("CLICKHOUSE_PASSWORD", ""),
        database=os.environ.get("CLICKHOUSE_DATABASE", "default"),
        secure=os.environ.get("CLICKHOUSE_SECURE", "1") != "0",
    )


def ingest(cabinet: str, log=print) -> int:
    rows = collect(cabinet)
    if rows:
        get_client().insert("ozon_products", rows, column_names=ROW_COLUMNS)
    log(f"  {cabinet}: товаров {len(rows)}, с брендом {sum(1 for r in rows if r[5])}")
    return len(rows)
