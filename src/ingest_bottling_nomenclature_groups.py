#!/usr/bin/env python3
# -*- coding: utf-8 -*-
from __future__ import annotations
"""
Загружает справочник «номенклатура → номенклатурная группа» из 1С OData
(Catalog_Номенклатура, только позиции с заполненной группой — у остальных
~4.8 тыс. позиций группы в 1С нет) в bottling.nomenclature_group.
Нужен для себестоимости по заказу (src/schema_bottling_cost.sql, раздел
«СЕБЕСТОИМОСТЬ ПО ЗАКАЗУ»). Маленький (≈400 строк), перезаливается целиком.

    python3 src/ingest_bottling_nomenclature_groups.py            # запись в CH (нужен доступ к ClickHouse)
    python3 src/ingest_bottling_nomenclature_groups.py --dump-json out.json
"""

import argparse
import json
import sys
from pathlib import Path

from dotenv_safe import load_dotenv

SCRIPT_DIR = Path(__file__).parent
load_dotenv(SCRIPT_DIR.parent / '.env')
sys.path.insert(0, str(SCRIPT_DIR))

from odata_bottling_core import EMPTY_GUID, build_guid_dict, odata_get_json  # noqa: E402

COLUMNS = ['nomenclature_key', 'nomenclature', 'nomenclature_group']
PAGE = 2000


def fetch_rows(guid_map: dict) -> list[list]:
    rows, skip = [], 0
    while True:
        # fetch_all() из core не умеет $filter; без фильтра $skip на этом справочнике
        # отдаёт 5000 из 5244 (страницы не стабильны) — поэтому фильтр по группе.
        d = odata_get_json(
            f"Catalog_Номенклатура?$format=json&$top={PAGE}&$skip={skip}"
            f"&$filter=НоменклатурнаяГруппа_Key ne guid'{EMPTY_GUID}'"
            f"&$select=Ref_Key,Description,НоменклатурнаяГруппа_Key")
        batch = d['value']
        rows += [[r['Ref_Key'], r['Description'], guid_map.get(r['НоменклатурнаяГруппа_Key'], '')] for r in batch]
        skip += len(batch)
        if len(batch) < PAGE:
            return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dump-json')
    ap.add_argument('--dry-run', action='store_true')
    args = ap.parse_args()
    rows = fetch_rows(build_guid_dict())
    unresolved = sum(1 for r in rows if not r[2])
    print(f'{len(rows)} номенклатур с группой, группа не расшифрована у {unresolved}')
    if args.dump_json:
        Path(args.dump_json).write_text(json.dumps({'columns': COLUMNS, 'rows': rows}, ensure_ascii=False), encoding='utf-8')
    if args.dry_run or args.dump_json:
        return
    from wb_core import get_client  # noqa: E402
    client = get_client(database='bottling')
    client.command('TRUNCATE TABLE nomenclature_group')
    client.insert('nomenclature_group', rows, column_names=COLUMNS)
    print('Готово.')


if __name__ == '__main__':
    main()
