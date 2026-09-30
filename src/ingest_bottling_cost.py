#!/usr/bin/env python3
# -*- coding: utf-8 -*-
from __future__ import annotations
"""
Загружает в ClickHouse (bottling.cost_entries) проводки по счетам
себестоимости клиента Боттлинг из 1С OData — для расчёта себестоимости
«ставкой месяца» (без партий). Схема и VIEW — src/schema_bottling_cost.sql,
там же — почему именно эти счета и как они связаны.

ИСТОЧНИК: функция `AccountingRegister_Хозрасчетный/RecordsWithExtDimensions`
(проводки ВМЕСТЕ с субконто). Обычный `..._RecordType` субконто не отдаёт
(гочтя, 2026-09-30). Один месяц ≈ 6.8 тыс. проводок, ≈3 минуты.

ФИЛЬТР: оставляются только проводки, где Дт или Кт — счёт 20.*, 23.*, 25,
28, 40, 43 или 90.02* (Active). Остальной журнал не нужен.

ЗАЩИТА ОТ СМЕНЫ УЧЁТА: для счетов из EXPECTED_KINDS проверяется, что
виды субконто именно те, на которые опираются VIEW (напр. у 20.01 первое
субконто — «Номенклатурные группы»). Если бухгалтер их переставит —
загрузка падает, а не пишет молча перепутанные колонки.

ИДЕМПОТЕНТНОСТЬ: перед вставкой месяца его партиция дропается.

ЗАПУСК (запись — только там, где доступен ClickHouse; см. docstring
ingest_bottling_realization.py):
    python3 src/ingest_bottling_cost.py --from 2026-01 --to 2026-01
    python3 src/ingest_bottling_cost.py --from 2026-01 --to 2026-01 --dry-run
    python3 src/ingest_bottling_cost.py --from 2026-01 --to 2026-01 --dump-json out.json
"""

import argparse
import calendar
import json
import re
import sys
from datetime import date
from pathlib import Path

from dotenv import load_dotenv

SCRIPT_DIR = Path(__file__).parent
load_dotenv(SCRIPT_DIR.parent / '.env')
sys.path.insert(0, str(SCRIPT_DIR))

from odata_bottling_core import EMPTY_GUID, build_guid_dict, fetch_all, odata_get_json  # noqa: E402

GUID_RE = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
FUNC = 'AccountingRegister_Хозрасчетный/RecordsWithExtDimensions'
PAGE = 2000

KEEP_PREFIXES = ('20.', '23.', '25', '28', '40', '43', '90.02')

# Виды субконто, на которые опираются VIEW (смысл колонок dr_ext*/cr_ext*).
EXPECTED_KINDS = {
    '20.01':   ('Номенклатурные группы', 'Статьи затрат', 'Продукция'),
    '25':      ('Статьи затрат', '-', '-'),
    '40':      ('Номенклатурные группы', 'Виды стоимости', '-'),
    '43':      ('Номенклатура', '-', 'Склады'),
    '90.02.1': ('Номенклатурные группы', '-', '-'),
}

COLUMNS = [
    'period', 'recorder', 'recorder_type', 'line_number',
    'dr_account', 'cr_account',
    'dr_ext1', 'dr_ext2', 'dr_ext3', 'cr_ext1', 'cr_ext2', 'cr_ext3',
    'dr_subdivision', 'cr_subdivision',
    'amount', 'qty_dr', 'qty_cr', 'content',
]


def keep(code_dr: str, code_cr: str) -> bool:
    return any(c.startswith(KEEP_PREFIXES) for c in (code_dr, code_cr))


def fetch_month(year: int, month: int) -> list[dict]:
    last = calendar.monthrange(year, month)[1]
    fn = (f"{FUNC}(StartPeriod=datetime'{year}-{month:02d}-01T00:00:00',"
          f"EndPeriod=datetime'{year}-{month:02d}-{last}T23:59:59')")
    rows: list[dict] = []
    skip = 0
    while True:
        batch = odata_get_json(f'{fn}?$format=json&$top={PAGE}&$skip={skip}')['value']
        rows.extend(batch)
        skip += len(batch)
        print(f'    {skip}')
        if len(batch) < PAGE:
            break
    return rows


def build_rows(raw: list[dict], acc_code: dict, kinds: dict, names: dict) -> tuple[list[list], dict]:
    def nm(key):
        return '' if not key or key == EMPTY_GUID else names.get(key, '')

    def ext(r, side, i):
        """Расшифрованное имя субконто; ('', '-') если пустое/не задано."""
        val = r.get(f'ExtDimension{side}{i}')
        typ = r.get(f'ExtDimension{side}{i}_Type')
        if not val or val == EMPTY_GUID or typ == 'StandardODATA.Undefined':
            return '', '-'
        kind = kinds.get(r.get(f'ExtDimensionType{side}{i}_Key'), '-')
        if not GUID_RE.match(val):  # перечисления (напр. «Виды стоимости») приходят уже текстом
            return val, kind
        return nm(val), kind

    out, stats = [], {'unresolved': 0, 'dropped_inactive': 0}
    for r in raw:
        if not r.get('Active'):
            stats['dropped_inactive'] += 1
            continue
        dr, cr = acc_code.get(r['AccountDr_Key'], '?'), acc_code.get(r['AccountCr_Key'], '?')
        if not keep(dr, cr):
            continue
        ed = [ext(r, 'Dr', i) for i in (1, 2, 3)]
        ec = [ext(r, 'Cr', i) for i in (1, 2, 3)]
        for acc, e in ((dr, ed), (cr, ec)):
            want = EXPECTED_KINDS.get(acc)
            # пустое субконто ('-') допустимо (напр. у части проводок 20.01 нет «Продукции»);
            # недопустим другой ВИД на том же месте
            if want and any(k != w and k != '-' for (_, k), w in zip(e, want)):
                raise RuntimeError(
                    f'Виды субконто счёта {acc} изменились: {tuple(k for _, k in e)} вместо {want} '
                    f'(проводка {r["Recorder"]}) — VIEW опираются на старый порядок, проверьте.')
        for name, kind in ed + ec:
            if name == '' and kind != '-':
                stats['unresolved'] += 1  # субконто задано, но имя в справочниках не нашлось
        out.append([
            r['Period'], r['Recorder'], (r.get('Recorder_Type') or '').replace('StandardODATA.', ''),
            int(r.get('LineNumber') or 0), dr, cr,
            ed[0][0], ed[1][0], ed[2][0], ec[0][0], ec[1][0], ec[2][0],
            nm(r.get('ПодразделениеDr_Key')), nm(r.get('ПодразделениеCr_Key')),
            float(r.get('Сумма') or 0), float(r.get('КоличествоDr') or 0),
            float(r.get('КоличествоCr') or 0), r.get('Содержание') or '',
        ])
    return out, stats


def months(frm: str, to: str):
    y, m = map(int, frm.split('-'))
    y2, m2 = map(int, to.split('-'))
    while (y, m) <= (y2, m2):
        yield y, m
        y, m = (y + 1, 1) if m == 12 else (y, m + 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--from', dest='frm', required=True, help='YYYY-MM')
    ap.add_argument('--to', dest='to', required=True, help='YYYY-MM')
    ap.add_argument('--dry-run', action='store_true', help='не писать в ClickHouse')
    ap.add_argument('--dump-json', help='сохранить строки в JSON (для загрузки в обход туннеля)')
    args = ap.parse_args()

    names = build_guid_dict()
    acc_code = {a['Ref_Key']: a['Code'] for a in fetch_all('ChartOfAccounts_Хозрасчетный', select='Ref_Key,Code')}
    kinds = {v['Ref_Key']: v['Description'] for v in
             fetch_all('ChartOfCharacteristicTypes_ВидыСубконтоХозрасчетные', select='Ref_Key,Description')}

    all_rows: dict[tuple[int, int], list[list]] = {}
    for y, m in months(args.frm, args.to):
        print(f'Месяц {y}-{m:02d}: тяну проводки с субконто...')
        raw = fetch_month(y, m)
        rows, stats = build_rows(raw, acc_code, kinds, names)
        print(f'  всего {len(raw)}, оставлено по счетам себестоимости {len(rows)}, {stats}')
        all_rows[(y, m)] = rows

    if args.dump_json:
        Path(args.dump_json).write_text(json.dumps(
            {'columns': COLUMNS, 'months': {f'{y}-{m:02d}': r for (y, m), r in all_rows.items()}},
            ensure_ascii=False), encoding='utf-8')
        print(f'Сохранено в {args.dump_json}')

    if args.dry_run:
        print('--dry-run: в ClickHouse не пишу.')
        return

    from wb_core import get_client  # noqa: E402
    from datetime import datetime
    client = get_client(database='bottling')
    for (y, m), rows in all_rows.items():
        client.command(f'ALTER TABLE cost_entries DROP PARTITION {y}{m:02d}')
        data = [[datetime.fromisoformat(r[0])] + r[1:] for r in rows]
        client.insert('cost_entries', data, column_names=COLUMNS)
        print(f'  {y}-{m:02d}: записано {len(rows)}')
    print('Готово.')


if __name__ == '__main__':
    main()
