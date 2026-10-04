#!/usr/bin/env python3
"""
Загрузка каталога товаров Ozon (offer_id, sku, бренд) в ClickHouse — таблица
ozon_products. Бренды нужны, чтобы разбить кабинеты Ozon по брендам: в отчётах
Ozon бренда нет, он есть только в карточке товара.

Примеры:
    python3 src/ingest_ozon_products.py --cabinet CloudSix
    python3 src/ingest_ozon_products.py --all-cabinets
    python3 src/ingest_ozon_products.py --all-cabinets --dry-run   # только прочитать из API
"""

import argparse
import json
import sys
import time
from collections import Counter
from pathlib import Path

from dotenv_safe import load_dotenv

REPO_ROOT = Path(__file__).parent.parent
load_dotenv(REPO_ROOT / ".env")

from cabinet_credentials import _keys_path  # noqa: E402
from ozon_products_core import collect, ingest  # noqa: E402


def cabinets_with_ozon() -> list[str]:
    with open(_keys_path(), encoding="utf-8") as f:
        data = json.load(f)
    return sorted(n for n, v in data.items() if v.get("ozon", {}).get("client_id"))


def main():
    p = argparse.ArgumentParser(description="Каталог товаров Ozon с брендами → ClickHouse")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--cabinet")
    g.add_argument("--all-cabinets", action="store_true")
    p.add_argument("--dry-run", action="store_true", help="прочитать из API и показать, ничего не записывая")
    p.add_argument("--delay", type=float, default=3.0, help="пауза между кабинетами, сек")
    args = p.parse_args()

    cabinets = cabinets_with_ozon() if args.all_cabinets else [args.cabinet]
    for i, cab in enumerate(cabinets, 1):
        print(f"[{i}/{len(cabinets)}] {cab}")
        try:
            if args.dry_run:
                rows = collect(cab)
                brands = Counter(r[5] or "(нет бренда в карточке)" for r in rows)
                print(f"  товаров {len(rows)}; бренды: {dict(brands.most_common())}")
            else:
                ingest(cab)
        except Exception as e:  # один кабинет не должен валить остальные
            print(f"  ОШИБКА {cab}: {e}", file=sys.stderr)
        if i < len(cabinets):
            time.sleep(args.delay)


if __name__ == "__main__":
    main()
