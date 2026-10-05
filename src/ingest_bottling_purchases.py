#!/usr/bin/env python3
# -*- coding: utf-8 -*-
from __future__ import annotations
"""
Загружает закупки (Document_ПоступлениеТоваровУслуг + «Товары») клиента
Боттлинг из 1С OData в bottling.purchase_lines. Схема и правила НДС —
src/schema_bottling_purchases.sql.

Загрузка по месяцам (как ingest_bottling_cost.py): партиция месяца
дропается и заливается заново.

Запуск (пишет в ClickHouse — только на проде или через туннель):
    python3 src/ingest_bottling_purchases.py --from 2026-01 --to 2026-09
    python3 src/ingest_bottling_purchases.py --from 2026-09 --to 2026-09 --dry-run
"""

import argparse
import calendar
import json
import sys
from collections import Counter
from pathlib import Path

from dotenv_safe import load_dotenv

SCRIPT_DIR = Path(__file__).parent
load_dotenv(SCRIPT_DIR.parent / '.env')
sys.path.insert(0, str(SCRIPT_DIR))

from odata_bottling_core import EMPTY_GUID, build_guid_dict, fetch_all  # noqa: E402

ENTITY = 'Document_ПоступлениеТоваровУслуг'
HEADER_FIELDS = [
    'Ref_Key', 'Number', 'Date', 'Posted', 'DeletionMark', 'Контрагент_Key',
    'ДоговорКонтрагента_Key', 'Склад_Key', 'НомерВходящегоДокумента',
    'СуммаВключаетНДС',
]
LINE_FIELDS = [
    'Ref_Key', 'LineNumber', 'Номенклатура_Key', 'ЕдиницаИзмерения_Key',
    'Количество', 'Цена', 'Сумма', 'СтавкаНДС', 'СуммаНДС', 'СчетУчета_Key',
]
COLUMNS = [
    'ref_key', 'line_number', 'number', 'date', 'posted', 'deletion_mark',
    'supplier', 'contract', 'warehouse', 'incoming_number', 'amount_includes_vat',
    'nomenclature', 'unit', 'quantity', 'price', 'raw_amount', 'vat_rate',
    'vat_amount', 'account_code',
]
CHUNK = 10  # ref_key в одном запросе строк (лимит длины URL в IIS)


def dec(guid_map: dict, key: str | None) -> str:
    return '' if not key or key == EMPTY_GUID else guid_map.get(key, '')


def fetch_month(year: int, month: int) -> tuple[list[dict], list[dict]]:
    last = calendar.monthrange(year, month)[1]
    flt = (f"Date ge datetime'{year}-{month:02d}-01T00:00:00' and "
           f"Date le datetime'{year}-{month:02d}-{last}T23:59:59'")
    headers = fetch_all(ENTITY, select=','.join(HEADER_FIELDS), flt=flt)
    lines: list[dict] = []
    refs = [h['Ref_Key'] for h in headers]
    for i in range(0, len(refs), CHUNK):
        f = ' or '.join(f"Ref_Key eq guid'{r}'" for r in refs[i:i + CHUNK])
        lines += fetch_all(f'{ENTITY}_Товары', select=','.join(LINE_FIELDS), flt=f)
    return headers, lines


def build_rows(headers: list[dict], lines: list[dict], guid_map: dict) -> list[list]:
    from datetime import datetime
    hdr = {h['Ref_Key']: h for h in headers}
    out = []
    for ln in lines:
        h = hdr.get(ln['Ref_Key'])
        if h is None:
            continue
        out.append([
            h['Ref_Key'], int(ln.get('LineNumber') or 0), h.get('Number') or '',
            datetime.fromisoformat(h['Date']),
            1 if h.get('Posted') else 0, 1 if h.get('DeletionMark') else 0,
            dec(guid_map, h.get('Контрагент_Key')), dec(guid_map, h.get('ДоговорКонтрагента_Key')),
            dec(guid_map, h.get('Склад_Key')), h.get('НомерВходящегоДокумента') or '',
            1 if h.get('СуммаВключаетНДС') else 0,
            dec(guid_map, ln.get('Номенклатура_Key')), dec(guid_map, ln.get('ЕдиницаИзмерения_Key')),
            float(ln.get('Количество') or 0), float(ln.get('Цена') or 0), float(ln.get('Сумма') or 0),
            ln.get('СтавкаНДС') or '', float(ln.get('СуммаНДС') or 0),
            dec(guid_map, ln.get('СчетУчета_Key')),
        ])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--from', dest='frm', required=True, help='YYYY-MM')
    ap.add_argument('--to', dest='to', required=True, help='YYYY-MM')
    ap.add_argument('--dry-run', action='store_true', help='не писать в ClickHouse')
    ap.add_argument('--dump-json', help='сохранить строки в JSON')
    args = ap.parse_args()

    fy, fm = map(int, args.frm.split('-'))
    ty, tm = map(int, args.to.split('-'))
    months = []
    y, m = fy, fm
    while (y, m) <= (ty, tm):
        months.append((y, m))
        y, m = (y + 1, 1) if m == 12 else (y, m + 1)

    guid_map = build_guid_dict()
    by_month: dict[tuple[int, int], list[list]] = {}
    for y, m in months:
        print(f'{y}-{m:02d}: тяну поступления...')
        headers, lines = fetch_month(y, m)
        rows = build_rows(headers, lines, guid_map)
        by_month[(y, m)] = rows
        acc = Counter(r[-1] for r in rows)
        print(f'  документов {len(headers)}, строк {len(rows)}, счета учёта: {dict(acc)}')
        unresolved = sum(1 for r in rows if not r[11])
        if unresolved:
            print(f'  ВНИМАНИЕ: {unresolved} строк без расшифровки номенклатуры', file=sys.stderr)

    if args.dump_json:
        Path(args.dump_json).write_text(json.dumps(
            {f'{y}-{m:02d}': [[str(c) if hasattr(c, 'isoformat') else c for c in r] for r in rows]
             for (y, m), rows in by_month.items()}, ensure_ascii=False), encoding='utf-8')
        print(f'Сохранено в {args.dump_json}')
    if args.dry_run:
        return

    from wb_core import get_client  # noqa: E402
    client = get_client(database='bottling')
    for (y, m), rows in by_month.items():
        client.command(f'ALTER TABLE purchase_lines DROP PARTITION {y}{m:02d}')
        client.insert('purchase_lines', rows, column_names=COLUMNS)
        print(f'  {y}-{m:02d}: записано {len(rows)}')


if __name__ == '__main__':
    main()
