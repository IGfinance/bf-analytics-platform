#!/usr/bin/env python3
"""
Разовая проверка всех ключей из secrets/cabinet_api_keys.json — по ОДНОМУ
одиночному запросу на 1 день данных на каждый WB/Ozon-кабинет, без
ретраев и без записи в ClickHouse. Между запросами — пауза (--delay),
чтобы не словить блокировку ключа при первом обращении (см. переписку
2026-09-20 — уже была блокировка).

Ozon-кабинеты без client_id (см. _todo в JSON) пропускаются.

Пример:
    python3 scripts/probe_cabinet_api_keys.py
    python3 scripts/probe_cabinet_api_keys.py --delay 90 --date 2026-09-18
    python3 scripts/probe_cabinet_api_keys.py --cabinets CloudSix,Torado
"""

import argparse
import json
import sys
import time
from datetime import date, timedelta
from pathlib import Path

import requests
from dotenv import load_dotenv

SCRIPT_DIR = Path(__file__).parent
REPO_ROOT = SCRIPT_DIR.parent
load_dotenv(REPO_ROOT / ".env")
sys.path.insert(0, str(REPO_ROOT / "src"))

from cabinet_credentials import _keys_path  # noqa: E402

WB_URL = "https://statistics-api.wildberries.ru/api/v5/supplier/reportDetailByPeriod"
OZON_URL = "https://api-seller.ozon.ru/v3/finance/transaction/list"


def probe_wb(cabinet: str, token: str, day: date, limit: int, log=print) -> None:
    params = {"dateFrom": day.isoformat(), "dateTo": day.isoformat(), "limit": limit, "rrdid": 0}
    headers = {"Authorization": token}
    log(f"  GET {WB_URL} dateFrom=dateTo={day} limit={limit}")
    try:
        resp = requests.get(WB_URL, params=params, headers=headers, timeout=60)
    except requests.RequestException as e:
        log(f"  ОШИБКА запроса: {e}")
        return

    rl = {k: v for k, v in resp.headers.items() if "ratelimit" in k.lower() or k.lower() == "retry-after"}
    log(f"  HTTP {resp.status_code}" + (f"  rate-limit={rl}" if rl else ""))
    if resp.status_code == 429:
        log("  429 — лимит уже сработал на первом запросе. Не ретраим.")
        return
    if resp.status_code >= 400:
        log(f"  Тело ответа: {resp.text[:500]}")
        return
    rows = resp.json() or []
    log(f"  Строк: {len(rows)}")
    if rows:
        r = rows[0]
        log(f"  supplier: {r.get('ppvz_supplier_name')!r}  inn: {r.get('ppvz_inn')!r}")


def probe_ozon(cabinet: str, client_id: str, api_key: str, day: date, page_size: int, log=print) -> None:
    payload = {
        "filter": {
            "date": {"from": f"{day.isoformat()}T00:00:00.000Z", "to": f"{day.isoformat()}T23:59:59.000Z"},
            "transaction_type": "all",
        },
        "page": 1,
        "page_size": page_size,
    }
    headers = {"Client-Id": client_id, "Api-Key": api_key, "Content-Type": "application/json"}
    log(f"  POST {OZON_URL} date={day} page_size={page_size} client_id={client_id}")
    try:
        resp = requests.post(OZON_URL, json=payload, headers=headers, timeout=60)
    except requests.RequestException as e:
        log(f"  ОШИБКА запроса: {e}")
        return

    rl = {k: v for k, v in resp.headers.items() if "ratelimit" in k.lower() or k.lower() == "retry-after"}
    log(f"  HTTP {resp.status_code}" + (f"  rate-limit={rl}" if rl else ""))
    if resp.status_code == 429:
        log("  429 — лимит уже сработал на первом запросе. Не ретраим.")
        return
    if resp.status_code >= 400:
        log(f"  Тело ответа: {resp.text[:500]}")
        return
    result = resp.json().get("result", {})
    ops = result.get("operations", [])
    log(f"  Операций: {len(ops)} (page_count={result.get('page_count')})")


def main():
    parser = argparse.ArgumentParser(description="Разовая проверка API-ключей по кабинетам (1 день, без ретраев)")
    parser.add_argument("--date", help="День для проверки, YYYY-MM-DD (по умолчанию: вчера)")
    parser.add_argument("--delay", type=float, default=60.0, help="Пауза между запросами, сек (по умолчанию 60)")
    parser.add_argument("--limit", type=int, default=50, help="WB: limit в запросе (по умолчанию 50)")
    parser.add_argument("--page-size", type=int, default=50, help="Ozon: page_size (по умолчанию 50)")
    parser.add_argument("--cabinets", help="Ограничить списком через запятую, напр. CloudSix,Torado")
    parser.add_argument("--dry-run", action="store_true", help="Только показать план запросов, без обращений к API")
    args = parser.parse_args()

    day = date.fromisoformat(args.date) if args.date else date.today() - timedelta(days=1)

    keys_path = _keys_path()
    if not keys_path.exists():
        print(f"Не найден {keys_path}", file=sys.stderr)
        sys.exit(1)
    with open(keys_path, encoding="utf-8") as f:
        data = json.load(f)

    only = set(args.cabinets.split(",")) if args.cabinets else None

    jobs = []
    for cabinet in sorted(data):
        if only and cabinet not in only:
            continue
        entry = data[cabinet]
        wb = entry.get("wb")
        if wb and wb.get("token"):
            jobs.append(("wb", cabinet, wb))
        ozon = entry.get("ozon")
        if ozon and ozon.get("api_key"):
            if not ozon.get("client_id"):
                print(f"[skip] {cabinet} Ozon — нет client_id (заполнить в {keys_path.name})")
                continue
            jobs.append(("ozon", cabinet, ozon))

    print(f"День проверки: {day}. Пауза между запросами: {args.delay}s. Всего запросов: {len(jobs)}.")
    for platform, cabinet, entry in jobs:
        print(f"  - {platform.upper():4s} {cabinet} (legal_entity={entry.get('legal_entity')})")
    if args.dry_run:
        return

    for i, (platform, cabinet, entry) in enumerate(jobs):
        if i > 0:
            print(f"\n  ... пауза {args.delay}s ...")
            time.sleep(args.delay)
        print(f"\n[{i + 1}/{len(jobs)}] {platform.upper()} — {cabinet} (legal_entity={entry.get('legal_entity')})")
        if platform == "wb":
            probe_wb(cabinet, entry["token"], day, args.limit)
        else:
            probe_ozon(cabinet, entry["client_id"], entry["api_key"], day, args.page_size)

    print("\nГотово.")


if __name__ == "__main__":
    main()
