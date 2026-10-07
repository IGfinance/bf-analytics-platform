#!/usr/bin/env python3
# -*- coding: utf-8 -*-
from __future__ import annotations
"""
Загружает в ClickHouse (bottling.credit_entries, bottling.credit_contracts)
кредиты и займы клиента Боттлинг из 1С OData: тело (счета 66.01/.03, 67.01/.03 …)
и проценты (66.02/.04, 67.02/.04 …). Схема, VIEW и смысл статуса «оплачен» —
src/schema_bottling_credits.sql.

ИСТОЧНИК: функция `AccountingRegister_Хозрасчетный/RecordsWithExtDimensions`
(проводки вместе с субконто — см. ingest_bottling_cost.py). Договор и
контрагент берутся из субконто той стороны проводки, где стоит счёт 66/67,
по ТИПУ субконто (Catalog_ДоговорыКонтрагентов / Catalog_Контрагенты), а не по
номеру позиции.

ИСТОРИЯ. Статус «оплачен» считается FIFO по всей жизни договора, поэтому
грузить нужно с самого начала учёта. Займы тянутся с 2017 года (договор
№5 от 18.08.2017), а база активна с 2018 — по умолчанию --from 2018-01.
Один месяц читается 1–3 минуты (журнал фильтруется на нашей стороне:
серверный $filter по счетам функция не принимает), вся история ≈ 1.5 часа.
Поэтому есть --dump-json: выгрузить в файл, потом отдельно загрузить
(--load-json) там, где доступен ClickHouse.

ИДЕМПОТЕНТНОСТЬ: перед вставкой месяца его партиция дропается; справочник
договоров — upsert по ключу (договоры загруженных месяцев перезаписываются).

ЗАЩИТА ОТ СМЕНЫ УЧЁТА: если у ноги по 66/67 нет субконто «Договор» —
загрузка падает с номером проводки (иначе тело/проценты молча уехали бы
в «пустой» договор).

ЗАПУСК:
    python3 src/ingest_bottling_credits.py --from 2018-01 --to 2026-10 --dump-json credits.json
    python3 src/ingest_bottling_credits.py --load-json credits.json        # запись в ClickHouse
    python3 src/ingest_bottling_credits.py --from 2026-09 --to 2026-10      # инкремент, сразу в ClickHouse
    python3 src/ingest_bottling_credits.py --from 2026-09 --to 2026-10 --dry-run
"""

import argparse
import json
import sys
from datetime import date, datetime
from pathlib import Path

from dotenv_safe import load_dotenv

SCRIPT_DIR = Path(__file__).parent
load_dotenv(SCRIPT_DIR.parent / '.env')
sys.path.insert(0, str(SCRIPT_DIR))

from odata_bottling_core import EMPTY_GUID, fetch_all, odata_get_json  # noqa: E402
from ingest_bottling_cost import fetch_month, months  # noqa: E402

# Тело и проценты по плану счетов 1С (66 — краткосрочные, 67 — долгосрочные;
# .2x — те же счета в валюте).
BODY_ACCOUNTS = {'66.01', '66.03', '66.05', '66.21', '66.23', '66.25',
                 '67.01', '67.03', '67.05', '67.21', '67.23', '67.25'}
INTEREST_ACCOUNTS = {'66.02', '66.04', '66.06', '66.22', '66.24', '66.26',
                     '67.02', '67.04', '67.06', '67.22', '67.24', '67.26'}

ENTRY_COLUMNS = ['period', 'recorder', 'recorder_type', 'line_number', 'account', 'part',
                 'side', 'corr_account', 'contract_key', 'amount', 'content']
CONTRACT_COLUMNS = ['contract_key', 'contract', 'counterparty', 'kind', 'rate', 'rate_type',
                    'signed_at', 'term_end', 'limit_amount', 'closed', 'comment']

CONTRACT_TYPE = 'StandardODATA.Catalog_ДоговорыКонтрагентов'


def part_of(account: str) -> str | None:
    if account in BODY_ACCOUNTS:
        return 'body'
    if account in INTEREST_ACCOUNTS:
        return 'interest'
    return None


def contract_of(r: dict, side: str) -> str | None:
    """GUID договора из субконто стороны (Dr/Cr) — по типу значения."""
    for i in (1, 2, 3):
        if r.get(f'ExtDimension{side}{i}_Type') == CONTRACT_TYPE:
            val = r.get(f'ExtDimension{side}{i}')
            if val and val != EMPTY_GUID:
                return val
    return None


def build_legs(raw: list[dict], acc_code: dict) -> list[list]:
    out = []
    for r in raw:
        if not r.get('Active'):
            continue
        dr, cr = acc_code.get(r['AccountDr_Key'], '?'), acc_code.get(r['AccountCr_Key'], '?')
        for side, acc, corr, ru_side in (('Dr', dr, cr, 'Дт'), ('Cr', cr, dr, 'Кт')):
            part = part_of(acc)
            if part is None:
                continue
            key = contract_of(r, side)
            if key is None:
                raise RuntimeError(f'Нет субконто «Договор» у ноги {ru_side} {acc} '
                                   f'(проводка {r["Recorder"]}, строка {r.get("LineNumber")}) — '
                                   f'учёт изменился, проверьте разбор.')
            out.append([
                r['Period'], r['Recorder'], (r.get('Recorder_Type') or '').replace('StandardODATA.', ''),
                int(r.get('LineNumber') or 0), acc, part, ru_side, corr, key,
                float(r.get('Сумма') or 0), r.get('Содержание') or '',
            ])
    return out


def _date(v: str | None) -> str | None:
    """OData отдаёт пустую дату как 0001-01-01T00:00:00 — это NULL."""
    if not v or v.startswith('0001-01-01'):
        return None
    return v[:10]


def fetch_contracts(keys: set[str]) -> list[list]:
    """Карточки договоров по GUID (по одной — их ~120, без постраничного каталога)."""
    owners: dict[str, str] = {}
    rows = []
    for key in sorted(keys):
        c = odata_get_json(f"Catalog_ДоговорыКонтрагентов(guid'{key}')?$format=json")
        owner = c.get('Owner_Key')
        if owner and owner not in owners:
            owners[owner] = (odata_get_json(f"Catalog_Контрагенты(guid'{owner}')?$format=json")
                             .get('Description') or '').strip()
        rows.append([
            key, (c.get('Description') or '').strip(), owners.get(owner, ''), c.get('ВидДоговора') or '',
            float(c.get('ПроцентнаяСтавка') or 0), c.get('ТипПроцентнойСтавки') or '',
            _date(c.get('Дата')), _date(c.get('СрокДействия')), float(c.get('Сумма') or 0),
            1 if c.get('ДоговорЗакрыт') else 0, (c.get('Комментарий') or '').strip(),
        ])
    return rows


def write_clickhouse(entries_by_month: dict[str, list[list]], contracts: list[list]) -> None:
    from wb_core import get_client  # noqa: E402
    client = get_client(database='bottling')
    for ym, rows in sorted(entries_by_month.items()):
        client.command(f'ALTER TABLE credit_entries DROP PARTITION {ym.replace("-", "")}')
        data = [[datetime.fromisoformat(r[0])] + r[1:] for r in rows]
        if data:
            client.insert('credit_entries', data, column_names=ENTRY_COLUMNS)
        print(f'  {ym}: записано {len(rows)}')
    # Справочник — upsert по ключу, а не TRUNCATE: при инкременте (один месяц)
    # в нём только договоры этого месяца, остальные стирать нельзя.
    if contracts:
        in_list = ','.join("'" + r[0] + "'" for r in contracts)
        client.command(f'ALTER TABLE credit_contracts DELETE WHERE contract_key IN ({in_list}) '
                       f'SETTINGS mutations_sync = 1')
    data = [r[:6] + [date.fromisoformat(r[6]) if r[6] else None,
                     date.fromisoformat(r[7]) if r[7] else None] + r[8:] for r in contracts]
    client.insert('credit_contracts', data, column_names=CONTRACT_COLUMNS)
    print(f'  договоров: {len(contracts)}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--from', dest='frm', default='2018-01', help='YYYY-MM (по умолчанию 2018-01)')
    ap.add_argument('--to', dest='to', help='YYYY-MM (по умолчанию — текущий месяц)')
    ap.add_argument('--dry-run', action='store_true', help='не писать в ClickHouse')
    ap.add_argument('--dump-json', help='сохранить ноги и договоры в JSON')
    ap.add_argument('--load-json', help='не читать 1С — записать в ClickHouse из JSON')
    args = ap.parse_args()

    if args.load_json:
        d = json.loads(Path(args.load_json).read_text(encoding='utf-8'))
        write_clickhouse(d['months'], d['contracts'])
        print('Готово.')
        return

    to = args.to or date.today().strftime('%Y-%m')
    acc_code = {a['Ref_Key']: a['Code'] for a in fetch_all('ChartOfAccounts_Хозрасчетный', select='Ref_Key,Code')}

    by_month: dict[str, list[list]] = {}
    for y, m in months(args.frm, to):
        print(f'Месяц {y}-{m:02d}: тяну проводки...')
        raw = fetch_month(y, m)
        legs = build_legs(raw, acc_code)
        print(f'  всего {len(raw)}, ног по 66/67: {len(legs)}')
        by_month[f'{y}-{m:02d}'] = legs

    keys = {r[8] for rows in by_month.values() for r in rows}
    print(f'Договоров в проводках: {len(keys)} — тяну карточки...')
    contracts = fetch_contracts(keys)

    if args.dump_json:
        Path(args.dump_json).write_text(json.dumps(
            {'entry_columns': ENTRY_COLUMNS, 'contract_columns': CONTRACT_COLUMNS,
             'months': by_month, 'contracts': contracts}, ensure_ascii=False), encoding='utf-8')
        print(f'Сохранено в {args.dump_json}')

    if args.dry_run:
        print('--dry-run: в ClickHouse не пишу.')
        return
    write_clickhouse(by_month, contracts)
    print('Готово.')


if __name__ == '__main__':
    main()
