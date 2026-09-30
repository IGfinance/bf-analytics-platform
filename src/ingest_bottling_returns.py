#!/usr/bin/env python3
# -*- coding: utf-8 -*-
from __future__ import annotations
"""
Загружает «Возврат товаров от покупателя» клиента Боттлинг из 1С OData
в ClickHouse: bottling.returns (одна строка = строка табличной части
«Товары» + реквизиты шапки документа). Схема — src/schema_bottling_returns.sql,
там же VIEW returns_net (проведённые, сумма БЕЗ НДС) — её использует
себестоимость/дашборд («Чистая выручка» = Выручка − Возвраты).

Объём небольшой (≈600 документов на 2026-09-30), перезаливается целиком
(ReplacingMergeTree по (ref_key, line_number) — повторный запуск
перезаписывает те же строки).

    python3 src/ingest_bottling_returns.py                     # запись в CH (нужен доступ к ClickHouse)
    python3 src/ingest_bottling_returns.py --dump-json out.json # без записи (для загрузки через Metabase)
"""

import argparse
import json
import sys
from pathlib import Path

from dotenv import load_dotenv

SCRIPT_DIR = Path(__file__).parent
load_dotenv(SCRIPT_DIR.parent / '.env')
sys.path.insert(0, str(SCRIPT_DIR))

from odata_bottling_core import EMPTY_GUID, build_guid_dict, fetch_all  # noqa: E402

HEADER = 'Document_ВозвратТоваровОтПокупателя'
HEADER_FIELDS = ['Ref_Key', 'Number', 'Date', 'Posted', 'DeletionMark', 'ВидОперации',
                 'Контрагент_Key', 'СуммаВключаетНДС', 'СуммаДокумента']
LINE_FIELDS = ['Ref_Key', 'LineNumber', 'Номенклатура_Key', 'Количество', 'Сумма', 'СуммаНДС']

COLUMNS = ['ref_key', 'line_number', 'number', 'date', 'posted', 'deletion_mark', 'operation',
           'counterparty', 'amount_includes_vat', 'document_amount',
           'nomenclature_key', 'nomenclature', 'quantity', 'amount', 'vat_amount']


def build_rows(headers: list[dict], lines: list[dict], names: dict) -> list[list]:
    nm = lambda k: '' if not k or k == EMPTY_GUID else names.get(k, '')  # noqa: E731
    h = {r['Ref_Key']: r for r in headers}
    out = []
    for ln in lines:
        d = h.get(ln['Ref_Key'])
        if d is None:
            continue
        out.append([
            ln['Ref_Key'], int(ln.get('LineNumber') or 0), d.get('Number') or '', d['Date'],
            1 if d.get('Posted') else 0, 1 if d.get('DeletionMark') else 0, d.get('ВидОперации') or '',
            nm(d.get('Контрагент_Key')), 1 if d.get('СуммаВключаетНДС') else 0, float(d.get('СуммаДокумента') or 0),
            ln.get('Номенклатура_Key') or '', nm(ln.get('Номенклатура_Key')),
            float(ln.get('Количество') or 0), float(ln.get('Сумма') or 0), float(ln.get('СуммаНДС') or 0),
        ])
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dump-json')
    args = ap.parse_args()
    names = build_guid_dict()
    headers = fetch_all(HEADER, select=','.join(HEADER_FIELDS), page=2000)
    lines = fetch_all(f'{HEADER}_Товары', select=','.join(LINE_FIELDS), page=2000)
    rows = build_rows(headers, lines, names)
    print(f'{len(headers)} документов, {len(lines)} строк, к записи {len(rows)}; '
          f'проведено {sum(1 for r in rows if r[4] == 1 and r[5] == 0)} строк')
    if args.dump_json:
        Path(args.dump_json).write_text(json.dumps({'columns': COLUMNS, 'rows': rows}, ensure_ascii=False), encoding='utf-8')
        return
    from datetime import datetime
    from wb_core import get_client  # noqa: E402
    client = get_client(database='bottling')
    client.insert('returns', [[r[0], r[1], r[2], datetime.fromisoformat(r[3])] + r[4:] for r in rows], column_names=COLUMNS)
    print('Готово.')


if __name__ == '__main__':
    main()
