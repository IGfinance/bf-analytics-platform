#!/usr/bin/env python3
# -*- coding: utf-8 -*-
from __future__ import annotations
"""
Загружает в ClickHouse (bottling.material_folder) папки номенклатуры «Алабуга
Боттлинг»: для каждой позиции Catalog_Номенклатура (не папки) — полный путь по
иерархии справочника и КАТЕГОРИЯ материала для «Подробной себестоимости»
(раскрытие слоя «Материалы» до уровня «этикетки», «QR-коды», «преформы»…).
Схема — src/schema_bottling_cost.sql (раздел material_folder).

Правило категории (по пути папок):
  «Сырье и материалы / <X> / ...»  -> X          (подпапки глубже уровня X сворачиваются,
                                                  напр. QR-коды / qr-код упаковка -> QR-коды)
  «Сырье и материалы» (без подпапки) -> «Сырьё и материалы (без папки)»
  «<другая корневая> / <X> ...»     -> «<корень>: <X>»
  позиция в корне справочника        -> «Без папки»
Если нужна своя группировка (например «упаковка» = пленка + колпачки) — правьте
CATEGORY_OVERRIDES ниже, а не VIEW.

В проводках cost_entries хранятся НАЗВАНИЯ материалов, не ключи — VIEW
соединяются по названию (при дублях названий берётся любая категория; скрипт
печатает число дублей с разными категориями).

    python3 src/ingest_bottling_material_folders.py            # запись в CH
    python3 src/ingest_bottling_material_folders.py --dump-json out.json
"""

import argparse
import collections
import json
import sys
from pathlib import Path

from dotenv import load_dotenv

SCRIPT_DIR = Path(__file__).parent
load_dotenv(SCRIPT_DIR.parent / '.env')
sys.path.insert(0, str(SCRIPT_DIR))

from odata_bottling_core import EMPTY_GUID, odata_get_json  # noqa: E402

COLUMNS = ['nomenclature_key', 'nomenclature', 'folder_path', 'material_category']
RAW = 'Сырье и материалы'
CATEGORY_OVERRIDES: dict[str, str] = {}  # {'пленка': 'Упаковка', 'колпачки, пробки, крышки, ручки': 'Упаковка'}


def category(path: list[str]) -> str:
    if not path:
        return 'Без папки'
    if path[0] == RAW:
        c = path[1] if len(path) > 1 else 'Сырьё и материалы (без папки)'
    else:
        c = f'{path[0]}: {path[1]}' if len(path) > 1 else path[0]
    return CATEGORY_OVERRIDES.get(c, c)


def fetch_catalog() -> list[dict]:
    # $orderby=Ref_Key — без стабильной сортировки $skip на этом справочнике теряет строки
    rows, skip = [], 0
    while True:
        b = odata_get_json(f"Catalog_Номенклатура?$format=json&$top=1000&$skip={skip}&$orderby=Ref_Key"
                           f"&$select=Ref_Key,Description,Parent_Key,IsFolder")['value']
        rows += b
        skip += len(b)
        if len(b) < 1000:
            return rows


def build_rows(cat: list[dict]) -> list[list]:
    by = {r['Ref_Key']: r for r in cat}

    def path(k):
        p = []
        while k and k != EMPTY_GUID and k in by:
            p.append(by[k]['Description'].strip())
            k = by[k]['Parent_Key']
        return list(reversed(p))

    out = []
    for r in cat:
        if r['IsFolder']:
            continue
        p = path(r['Parent_Key'])
        out.append([r['Ref_Key'], r['Description'].strip(), ' / '.join(p), category(p)])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dump-json')
    args = ap.parse_args()
    rows = build_rows(fetch_catalog())
    cats = collections.defaultdict(set)
    for r in rows:
        cats[r[1]].add(r[3])
    dup = sum(1 for v in cats.values() if len(v) > 1)
    print(f'{len(rows)} позиций; названий с разными категориями: {dup}')
    if args.dump_json:
        Path(args.dump_json).write_text(json.dumps({'columns': COLUMNS, 'rows': rows}, ensure_ascii=False), encoding='utf-8')
        return
    from wb_core import get_client  # noqa: E402
    client = get_client(database='bottling')
    client.command('TRUNCATE TABLE material_folder')
    client.insert('material_folder', rows, column_names=COLUMNS)
    print('Готово.')


if __name__ == '__main__':
    main()
