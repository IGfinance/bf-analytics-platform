#!/usr/bin/env python3
# -*- coding: utf-8 -*-
from __future__ import annotations
"""
Остатки на конец месяца по счетам 10.01 и 43 из 1С OData (функция
AccountingRegister_Хозрасчетный/BalanceAndTurnovers, закрывающий остаток месяца) в bottling.balances.
Схема и оговорки (43 — полная себестоимость, незакрытый месяц предварительный) —
src/schema_bottling_balances.sql.

    python3 src/ingest_bottling_balances.py --from 2025-12 --to 2026-09 --dump-json out.json --dry-run
    python3 src/ingest_bottling_balances.py --from 2026-09 --to 2026-09        # пишет в ClickHouse (прод)
"""

import argparse
import calendar
import json
import sys
from datetime import date
from pathlib import Path

from dotenv_safe import load_dotenv

SCRIPT_DIR = Path(__file__).parent
load_dotenv(SCRIPT_DIR.parent / '.env')
sys.path.insert(0, str(SCRIPT_DIR))

from odata_bottling_core import EMPTY_GUID, build_guid_dict, fetch_all, odata_get_json  # noqa: E402

ACCOUNTS = ('10.01', '43')
COLUMNS = ['month_end', 'account', 'nomenclature', 'warehouse', 'amount', 'quantity']
PAGE = 2000


def fetch_balance(month_end: date) -> list[dict]:
    """Остатки за месяц (BalanceAndTurnovers; берём СуммаClosingBalance).
    Функция Balance(Period=конец месяца) НЕ используется: на этой базе её значения
    не сходятся с движением по проводкам (январь 2026: 56,8 млн против 42,0 по
    оборотам), а BalanceAndTurnovers сходится (open + Дт − Кт = close, close месяца
    = open следующего)."""
    start = month_end.replace(day=1)
    fn = (f"BalanceAndTurnovers(StartPeriod=datetime'{start.isoformat()}T00:00:00',"
          f"EndPeriod=datetime'{month_end.isoformat()}T23:59:59')")
    rows: list[dict] = []
    skip = 0
    while True:
        batch = odata_get_json(
            f"AccountingRegister_Хозрасчетный/{fn}?$format=json&$top={PAGE}&$skip={skip}")['value']
        rows += batch
        skip += len(batch)
        if len(batch) < PAGE:
            return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--from', dest='frm', required=True, help='YYYY-MM')
    ap.add_argument('--to', dest='to', required=True, help='YYYY-MM')
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--dump-json')
    args = ap.parse_args()
    fy, fm = map(int, args.frm.split('-'))
    ty, tm = map(int, args.to.split('-'))
    months = []
    y, m = fy, fm
    while (y, m) <= (ty, tm):
        months.append(date(y, m, calendar.monthrange(y, m)[1]))
        y, m = (y + 1, 1) if m == 12 else (y, m + 1)

    acc = {r['Ref_Key']: r['Code'] for r in fetch_all('ChartOfAccounts_Хозрасчетный', select='Ref_Key,Code')}
    names = build_guid_dict()

    def nm(key):
        return '' if not key or key == EMPTY_GUID else names.get(key, '')

    out: dict[str, list[list]] = {}
    for me in months:
        rows = []
        for r in fetch_balance(me):
            code = acc.get(r['Account_Key'], '')
            if code not in ACCOUNTS:
                continue
            nom = nm(r.get('ExtDimension1')) if r.get('ExtDimension1_Type', '').endswith('Номенклатура') else ''
            wh = nm(r.get('ExtDimension3')) if r.get('ExtDimension3_Type', '').endswith('Склады') else ''
            amount, qty = float(r.get('СуммаClosingBalance') or 0), float(r.get('КоличествоClosingBalance') or 0)
            if amount == 0 and qty == 0:
                continue
            rows.append([me.isoformat(), code, nom, wh, amount, qty])
        out[me.isoformat()[:7]] = rows
        print(f"{me}: строк {len(rows)}, 10.01 = {sum(r[4] for r in rows if r[1] == '10.01'):,.0f}, "
              f"43 = {sum(r[4] for r in rows if r[1] == '43'):,.0f}")
    if args.dump_json:
        Path(args.dump_json).write_text(json.dumps(out, ensure_ascii=False), encoding='utf-8')
    if args.dry_run:
        return
    from wb_core import get_client  # noqa: E402
    client = get_client(database='bottling')
    for ym, rows in out.items():
        client.command(f"ALTER TABLE balances DROP PARTITION {ym.replace('-', '')}")
        client.insert('balances', [[date.fromisoformat(r[0])] + r[1:] for r in rows], column_names=COLUMNS)
        print(f'  {ym}: записано {len(rows)}')


if __name__ == '__main__':
    main()
