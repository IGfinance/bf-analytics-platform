#!/usr/bin/env python3
"""
Разовый ОДИНОЧНЫЙ тестовый запрос к WB Statistics API новым ключом
WILDBERRIES_API_2 (кабинет CloudSix) — без ретраев и без пагинации.

Делает ровно один GET с limit=5000 и печатает статус/заголовки/кол-во строк.
НЕ пишет ничего в ClickHouse. Если словили 429 — просто печатаем это и
выходим, никаких повторных попыток, чтобы не нагружать лимит.
"""

import os
from pathlib import Path

import requests
from dotenv import load_dotenv

SCRIPT_DIR = Path(__file__).parent
load_dotenv(SCRIPT_DIR.parent / ".env")

API_URL = "https://statistics-api.wildberries.ru/api/v5/supplier/reportDetailByPeriod"
DATE_FROM = "2026-09-08"
DATE_TO = "2026-09-10"
LIMIT = 5000

token = os.environ["WILDBERRIES_API_2"]
params = {"dateFrom": DATE_FROM, "dateTo": DATE_TO, "limit": LIMIT, "rrdid": 0}
headers = {"Authorization": token}

print(f"GET {API_URL}")
print(f"params={params}")

resp = requests.get(API_URL, params=params, headers=headers, timeout=120)

print(f"\nHTTP {resp.status_code}")
rl_headers = {k: v for k, v in resp.headers.items() if "ratelimit" in k.lower() or k.lower() == "retry-after"}
if rl_headers:
    print(f"Rate-limit headers: {rl_headers}")

if resp.status_code == 429:
    print("\n429 — лимит уже сработал на ПЕРВОМ запросе новым ключом. Ничего не ретраим.")
    print(resp.text[:1000])
else:
    resp.raise_for_status()
    data = resp.json() or []
    print(f"Строк получено: {len(data)}")
    if data:
        print("\nПример первой строки:")
        print(data[0])
        print(f"\nПоследний rrd_id на странице: {data[-1].get('rrd_id')}")
