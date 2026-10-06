#!/usr/bin/env python3
# -*- coding: utf-8 -*-
from __future__ import annotations
"""
Собирает события для разбора списаний июня 2026 (см. schema_bottling_writeoff_case.sql):
  * соки «ДБ» (3 позиции): оплаты поставщику (банк), взаимозачёты с ним, поступления, списание
    (требования + регл. операция);
  * вода «Святой ключ» 18,9 л: ручной ввод остатка 31.12.2025 и списание 30.06.2026.
Пишет JSON (--dump-json) и/или таблицу bottling.writeoff_case (пересоздаёт содержимое целиком).

    python3 src/ingest_bottling_writeoff_case.py --dump-json out.json --dry-run
"""

import argparse
import json
import sys
from datetime import date
from pathlib import Path

from dotenv_safe import load_dotenv

SCRIPT_DIR = Path(__file__).parent
load_dotenv(SCRIPT_DIR.parent / '.env')
sys.path.insert(0, str(SCRIPT_DIR))

from odata_bottling_core import build_guid_dict, fetch_all, odata_get_json  # noqa: E402

JUICES = ["ДБ СОК Яблоко 1л/12", "ДБ НК Яблоко-Персик 1л/12", "ДБ НК Мультифрукт 1л/12"]
WATER_NAME = "Вода питьевая ''Святой ключ'', негазированная, 18,9 л."
SUPPLIER_KEY = 'de95ed73-ff61-11e7-a23c-94de80b4ab85'   # ИМПЕРИЯ-ТРЕЙД ООО
# документы списания июня 2026 (Recorder GUID из bottling.cost_entries)
WRITEOFF_DOCS = {
    'e49717b8-8823-11f1-970b-d843ae4319c8': ('Document_ОперацияБух', 'ручная операция «Списание материалов»'),
    'efdfff41-73c3-11f1-9705-d843ae4319c8': ('Document_РегламентнаяОперация', 'регл. операция, «Корректировка стоимости списания»'),
    'a9c41eb1-8826-11f1-970b-d843ae4319c8': ('Document_ТребованиеНакладная', 'требование «Списание материалов в производство»'),
    '25df88dc-8826-11f1-970b-d843ae4319c8': ('Document_ТребованиеНакладная', 'требование «Списание материалов в производство»'),
}
OPENING_DOC = 'b0831a30-2cdf-11f1-96d7-d843ae4319c8'   # ПЛБП-000173, ввод остатка 31.12.2025
COLUMNS = ['case_name', 'stage_no', 'stage', 'event_date', 'document', 'counterparty', 'nomenclature',
           'quantity', 'price', 'amount', 'note']


def d10(s: str) -> str:
    return s[:10]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry-run', action='store_true')
    ap.add_argument('--dump-json')
    args = ap.parse_args()
    g = build_guid_dict()
    supplier = g.get(SUPPLIER_KEY, '')

    noms = fetch_all('Catalog_Номенклатура', select='Ref_Key,Description', page=2000,
                     flt=' or '.join(["Description eq '%s'" % n for n in JUICES]
                                     + ["Description eq '%s'" % WATER_NAME.replace("'", "''")]))
    by_name = {n['Description']: n['Ref_Key'] for n in noms}
    missing = [n for n in JUICES + [WATER_NAME] if n not in by_name]
    if missing:
        raise RuntimeError(f'Не найдена номенклатура: {missing}')
    juice_keys = {by_name[n]: n for n in JUICES}

    events: list[list] = []

    # 1. Оплаты поставщику (банк): все платежи контрагенту, назначение — «за соки и нектары»
    pays = fetch_all('Document_СписаниеСРасчетногоСчета',
                     select='Ref_Key,Number,Date,Posted,DeletionMark,ВидОперации,Контрагент,СуммаДокумента,НазначениеПлатежа',
                     flt="Date ge datetime'2023-01-01T00:00:00'")
    for p in pays:
        if p.get('Контрагент') == SUPPLIER_KEY and p['Posted'] and not p['DeletionMark']:
            events.append(['Соки ДБ', 1, 'Оплата поставщику', d10(p['Date']), f"Списание с р/с {p['Number']}", supplier, '',
                           0, 0, float(p['СуммаДокумента']), (p.get('НазначениеПлатежа') or '')[:200]])

    # 1б. Взаимозачёты с этим же контрагентом (он и поставщик, и покупатель): Document_КорректировкаДолга,
    # дебитор = кредитор = поставщик. Непроведённые (напр. ПЛБП-000085 «СписаниеЗадолженности» 2024) пропускаем.
    offsets = fetch_all('Document_КорректировкаДолга',
                        select='Ref_Key,Number,Date,Posted,DeletionMark,ВидОперации,КонтрагентДебитор_Key,КонтрагентКредитор_Key,СуммаДтЗадолженности,Комментарий',
                        flt=f"КонтрагентДебитор_Key eq guid'{SUPPLIER_KEY}' and КонтрагентКредитор_Key eq guid'{SUPPLIER_KEY}'")
    for o in offsets:
        if o['Posted'] and not o['DeletionMark'] and o['Date'] >= '2023-01-01':
            events.append(['Соки ДБ', 1, 'Взаимозачёт', d10(o['Date']), f"Корректировка долга {o['Number']}", supplier, '',
                           0, 0, float(o['СуммаДтЗадолженности']),
                           f"{o['ВидОперации']}: долг перед поставщиком закрыт встречной задолженностью этого же контрагента (продажи ему)"
                           + (f". {o['Комментарий']}" if o.get('Комментарий') else '')])

    # 2. Поступления соков
    f = ' or '.join(f"Номенклатура_Key eq guid'{k}'" for k in juice_keys)
    lines = fetch_all('Document_ПоступлениеТоваровУслуг_Товары',
                      select='Ref_Key,LineNumber,Номенклатура_Key,Количество,Сумма,СуммаНДС', flt=f)
    refs = sorted({l['Ref_Key'] for l in lines})
    hdr = {}
    for i in range(0, len(refs), 10):
        ff = ' or '.join(f"Ref_Key eq guid'{r}'" for r in refs[i:i + 10])
        for h in fetch_all('Document_ПоступлениеТоваровУслуг',
                           select='Ref_Key,Number,Date,Posted,DeletionMark,СуммаВключаетНДС', flt=ff):
            hdr[h['Ref_Key']] = h
    for l in lines:
        h = hdr[l['Ref_Key']]
        if not h['Posted'] or h['DeletionMark']:
            continue
        net = l['Сумма'] - l['СуммаНДС'] if h['СуммаВключаетНДС'] else l['Сумма']
        q = float(l['Количество'])
        events.append(['Соки ДБ', 2, 'Поступление на склад', d10(h['Date']), f"Поступление {h['Number']}", supplier,
                       juice_keys[l['Номенклатура_Key']], q, round(net / q, 4) if q else 0, round(net, 2),
                       'НДС к вычету, стоимость без НДС'])

    # 3. Списание июня: проводки Дт 20.01 / Кт 10.01 четырёх документов
    acc = {r['Ref_Key']: r['Code'] for r in fetch_all('ChartOfAccounts_Хозрасчетный', select='Ref_Key,Code')}
    entries = []
    for start, end in (('2026-06-01', '2026-06-30'), ('2025-12-01', '2025-12-31')):   # списание; ввод остатка
        skip = 0
        while True:
            b = odata_get_json("AccountingRegister_Хозрасчетный/RecordsWithExtDimensions("
                               f"StartPeriod=datetime'{start}T00:00:00',EndPeriod=datetime'{end}T23:59:59')"
                               f"?$format=json&$top=2000&$skip={skip}")['value']
            skip += len(b)
            entries += [r for r in b if r['Recorder'] in WRITEOFF_DOCS or r['Recorder'] == OPENING_DOC]
            if len(b) < 2000:
                break
    docnum = {}
    for rec, (ent, _) in WRITEOFF_DOCS.items():
        docnum[rec] = odata_get_json(f"{ent}?$format=json&$filter=Ref_Key eq guid'{rec}'&$select=Ref_Key,Number")['value'][0]['Number']
    water_key = by_name[WATER_NAME]
    for r in entries:
        if (r['Recorder'] not in WRITEOFF_DOCS or not r.get('Active')
                or acc.get(r['AccountDr_Key']) != '20.01' or acc.get(r['AccountCr_Key']) != '10.01'):
            continue
        key = r.get('ExtDimensionCr1')
        ent, note = WRITEOFF_DOCS[r['Recorder']]
        nm = juice_keys.get(key) or (WATER_NAME if key == water_key else None)
        if nm is None:
            continue
        case = 'Вода 18,9 л' if key == water_key else 'Соки ДБ'
        events.append([case, 3, 'Списание', '2026-06-30',
                       f"{ent.split('_')[1]} {docnum[r['Recorder']]}", '', nm,
                       float(r.get('КоличествоCr') or 0), 0, float(r.get('Сумма') or 0), note])

    # 4. Вода: ввод остатка 31.12.2025 (ручная операция, Дт 10.01 / Кт 000, без количества)
    opening = odata_get_json(f"Document_ОперацияБух?$format=json&$filter=Ref_Key eq guid'{OPENING_DOC}'&$select=Ref_Key,Number,Date")['value'][0]
    for r in entries:
        if r['Recorder'] == OPENING_DOC and r.get('ExtDimensionDr1') == water_key and acc.get(r['AccountDr_Key']) == '10.01':
            events.append(['Вода 18,9 л', 0, 'Ввод остатка', '2025-12-31', f"Операция {opening['Number']}", '', WATER_NAME,
                           0, 0, float(r['Сумма']), 'Дт 10.01 / Кт 000 «Вспомогательный счёт», вручную, без количества и склада'])

    events.sort(key=lambda e: (e[0], e[3], e[1]))
    print(f'событий: {len(events)}')
    for case in sorted({e[0] for e in events}):
        for st in sorted({e[1] for e in events if e[0] == case}):
            x = [e for e in events if e[0] == case and e[1] == st]
            print(f'  {case} / этап {st}: {len(x)} событий, сумма {sum(e[9] for e in x):,.0f}, кол-во {sum(e[7] for e in x):,.0f}')
    if args.dump_json:
        Path(args.dump_json).write_text(json.dumps(events, ensure_ascii=False), encoding='utf-8')
    if args.dry_run:
        return
    from wb_core import get_client  # noqa: E402
    client = get_client(database='bottling')
    client.command('TRUNCATE TABLE writeoff_case')
    client.insert('writeoff_case', [e[:3] + [date.fromisoformat(e[3])] + e[4:] for e in events], column_names=COLUMNS)
    print('записано')


if __name__ == '__main__':
    main()
