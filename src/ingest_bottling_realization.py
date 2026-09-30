#!/usr/bin/env python3
# -*- coding: utf-8 -*-
from __future__ import annotations
"""
Загружает "Реализацию товаров и услуг" клиента Боттлинг из 1С OData в
ClickHouse: bottling.realization_orders (шапка) и
bottling.realization_items (строки-товары). Схема — src/schema_bottling_realization.sql,
там же — почему именно эти два поля/эта фильтрация.

ВАЖНО про запуск: пишет в ClickHouse через clickhouse_connect на
CLICKHOUSE_HOST из .env (127.0.0.1:8123) — то есть только там, где
ClickHouse реально слушает (прод-VPS или открытый к нему SSH-туннель).
С обычной машины разработчика это упадёт Connection refused — тогда
используйте разовую загрузку через Metabase API (см. сессию 2026-09-30
в вики, там же лежит уже загруженный на 2026-09-29 снимок).

ГИДРАЦИЯ GUID: расшифровка контрагента/договора/склада и т.п. берётся из
общего кэша build_guid_dict() (см. odata_bottling_core.py) — тех же
справочников, что и в xlsx-выгрузке. Если справочник вырастет (новый
контрагент), кэш просто перечитывается заново при каждом запуске
(это не инкрементально, но справочники маленькие — секунды).

Идемпотентность: обе таблицы — ReplacingMergeTree по (ref_key) /
(ref_key, line_number), повторный запуск перезаписывает те же строки,
а не дублирует — дубли схлопнутся при следующем OPTIMIZE/FINAL.

Запуск:
    python3 src/ingest_bottling_realization.py
    python3 src/ingest_bottling_realization.py --dry-run   # без записи в CH
"""

import argparse
import sys
from pathlib import Path

from dotenv import load_dotenv

SCRIPT_DIR = Path(__file__).parent
load_dotenv(SCRIPT_DIR.parent / '.env')
sys.path.insert(0, str(SCRIPT_DIR))

from wb_core import get_client  # noqa: E402 — общий helper подключения к ClickHouse
from odata_bottling_core import (  # noqa: E402
    EMPTY_GUID, build_guid_dict, entity_fields, fetch_all, fetch_all_wide,
    key_field, load_metadata,
)

ENTITY = 'Document_РеализацияТоваровУслуг'

# Тот же сокращённый список полей заголовка, что в scripts/export_odata_bottling.py
# (см. там — почему: 91 поле для 150-тысячного документа стоит ~50 минут
# ради полей, которые у этого бизнеса всегда пустые). Формула НЕ
# продублирована случайно: если список правите — правьте оба места и
# сверяйте, но переносить в общий модуль пока рано — набор полей здесь
# завязан на КОНКРЕТНЫЕ колонки таблицы realization_orders, у xlsx-выгрузки
# он может отличаться (там могут захотеть больше полей "для изучения").
HEADER_FIELDS = [
    'Ref_Key', 'Number', 'Date', 'Posted', 'DeletionMark',
    'Контрагент_Key', 'ДоговорКонтрагента_Key', 'ТипЦен_Key',
    'ВалютаДокумента_Key', 'КурсВзаиморасчетов', 'СуммаВключаетНДС',
    'СуммаДокумента', 'Ответственный_Key',
]
LINE_FIELDS = [
    'Ref_Key', 'LineNumber', 'Номенклатура_Key', 'КоличествоМест',
    'ЕдиницаИзмерения_Key', 'Коэффициент', 'Количество', 'Цена',
    'Сумма', 'СтавкаНДС', 'СуммаНДС',
]


def decode(guid_map: dict, key: str | None) -> str:
    if not key or key == EMPTY_GUID:
        return ''
    return guid_map.get(key, '')


def build_orders_rows(header_rows: list[dict], guid_map: dict) -> list[list]:
    out = []
    for h in header_rows:
        out.append([
            h['Ref_Key'],
            h.get('Number') or '',
            h['Date'],
            1 if h.get('Posted') else 0,
            1 if h.get('DeletionMark') else 0,
            h.get('Контрагент_Key') or '',
            decode(guid_map, h.get('Контрагент_Key')),
            h.get('ДоговорКонтрагента_Key') or '',
            decode(guid_map, h.get('ДоговорКонтрагента_Key')),
            h.get('ТипЦен_Key') or '',
            decode(guid_map, h.get('ТипЦен_Key')),
            h.get('ВалютаДокумента_Key') or '',
            decode(guid_map, h.get('ВалютаДокумента_Key')),
            float(h.get('КурсВзаиморасчетов') or 0),
            1 if h.get('СуммаВключаетНДС') else 0,
            float(h.get('СуммаДокумента') or 0),
            h.get('Ответственный_Key') or '',
            decode(guid_map, h.get('Ответственный_Key')),
        ])
    return out


ORDERS_COLUMNS = [
    'ref_key', 'number', 'date', 'posted', 'deletion_mark',
    'counterparty_key', 'counterparty', 'contract_key', 'contract',
    'price_type_key', 'price_type', 'currency_key', 'currency',
    'exchange_rate', 'amount_includes_vat', 'document_amount',
    'responsible_key', 'responsible',
]


def build_items_rows(line_rows: list[dict], guid_map: dict) -> list[list]:
    out = []
    for line in line_rows:
        out.append([
            line['Ref_Key'],
            int(line.get('LineNumber') or 0),
            line.get('Номенклатура_Key') or '',
            decode(guid_map, line.get('Номенклатура_Key')),
            float(line.get('КоличествоМест') or 0),
            line.get('ЕдиницаИзмерения_Key') or '',
            decode(guid_map, line.get('ЕдиницаИзмерения_Key')),
            float(line.get('Коэффициент') or 0),
            float(line.get('Количество') or 0),
            float(line.get('Цена') or 0),
            float(line.get('Сумма') or 0),
            line.get('СтавкаНДС') or '',
            float(line.get('СуммаНДС') or 0),
        ])
    return out


ITEMS_COLUMNS = [
    'ref_key', 'line_number', 'nomenclature_key', 'nomenclature',
    'qty_places', 'unit_key', 'unit', 'coefficient', 'quantity',
    'price', 'amount', 'vat_rate', 'vat_amount',
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry-run', action='store_true', help='не писать в ClickHouse, только посчитать')
    args = ap.parse_args()

    print('Читаю $metadata...')
    xml = load_metadata()
    guid_map = build_guid_dict()

    key = key_field(xml, ENTITY)
    scalar, _ = entity_fields(xml, ENTITY)
    fields = [f for f in HEADER_FIELDS if f in scalar]
    missing = set(HEADER_FIELDS) - set(fields)
    if missing:
        raise RuntimeError(f'Полей нет в $metadata (проверьте 1С не переименовал их): {missing}')

    print('Тяну заголовки "Реализация товаров и услуг"...')
    header_rows = fetch_all_wide(ENTITY, fields, key, page=5000)
    print(f'  {len(header_rows)} документов')

    print('Тяну строки товаров...')
    line_rows = fetch_all(f'{ENTITY}_Товары', select=','.join(LINE_FIELDS), page=5000)
    print(f'  {len(line_rows)} строк товаров')

    orders_rows = build_orders_rows(header_rows, guid_map)
    items_rows = build_items_rows(line_rows, guid_map)

    n_posted = sum(1 for r in orders_rows if r[ORDERS_COLUMNS.index('posted')] == 1)
    print(f'  из них проведено: {n_posted} ({round(100 * n_posted / max(len(orders_rows), 1), 1)}%)')

    if args.dry_run:
        print('--dry-run: в ClickHouse не пишу.')
        return

    client = get_client(database='bottling')
    print('Пишу bottling.realization_orders...')
    client.insert('realization_orders', orders_rows, column_names=ORDERS_COLUMNS)
    print('Пишу bottling.realization_items...')
    client.insert('realization_items', items_rows, column_names=ITEMS_COLUMNS)
    print('Готово.')


if __name__ == '__main__':
    main()
