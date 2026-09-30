#!/usr/bin/env python3
# -*- coding: utf-8 -*-
from __future__ import annotations
"""
Выгружает выбранные объекты 1С OData («Алабуга Боттлинг») в .xlsx —
по одному файлу на объект, лист "Заголовок" + по листу на каждую
табличную часть (кроме штрихкодов маркировки — решение владельца
2026-09-29, см. docs/odata-alabuga-bottling-entities.md).

Только для изучения человеком. Формула доступа к OData (пагинация,
разбор $metadata, обход лимита длины query string, справочники для
расшифровки GUID) живёт в src/odata_bottling_core.py — общая с боевым
инжестом src/ingest_bottling_realization.py, здесь не дублируется.

Запуск:
    python3 scripts/export_odata_bottling.py Document_РеализацияТоваровУслуг ...
"""

import sys
import time
from datetime import datetime
from pathlib import Path

import openpyxl
from openpyxl.utils import get_column_letter

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / 'src'))

from odata_bottling_core import (  # noqa: E402
    EMPTY_GUID, build_guid_dict, entity_fields, fetch_all, fetch_all_wide,
    key_field, load_metadata,
)

OUT_DIR = REPO / 'data-files' / 'odata-bottling'


DATE_RE = None  # см. ниже


def coerce(value):
    import re as _re
    global DATE_RE
    if DATE_RE is None:
        DATE_RE = _re.compile(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}$')
    if isinstance(value, str) and DATE_RE.match(value):
        try:
            return datetime.fromisoformat(value)
        except ValueError:
            return value
    return value


def write_sheet(wb: openpyxl.Workbook, title: str, rows: list[dict], guid_map: dict[str, str]):
    ws = wb.create_sheet(title=title[:31])
    if not rows:
        ws.append(['(нет строк)'])
        return
    cols = list(rows[0].keys())
    header = []
    for c in cols:
        header.append(c)
        if c.endswith('_Key') and not c.endswith('_Type_Key'):
            header.append(c[:-4] + ' (расшифровка)')
    ws.append(header)
    for row in rows:
        line = []
        for c in cols:
            v = coerce(row.get(c))
            line.append(v)
            if c.endswith('_Key') and not c.endswith('_Type_Key'):
                if v in (None, '', EMPTY_GUID):
                    line.append('')
                else:
                    line.append(guid_map.get(v, ''))
        ws.append(line)
    # автоширина по первым 200 строкам
    for i, c in enumerate(header, start=1):
        maxlen = max([len(c)] + [len(str(ws.cell(r, i).value or '')) for r in range(2, min(len(rows), 200) + 2)])
        ws.column_dimensions[get_column_letter(i)].width = min(max(maxlen + 2, 10), 60)
    ws.freeze_panes = 'A2'


BARCODE_TABULAR_SKIP = {'ШтрихкодыУпаковок'}

# Замер 2026-09-29: страница из ~20 широких полей стоит серверу 5-10с вне
# зависимости от $skip (не деградация OFFSET — чистая цена ширины выборки
# на 1С). У 150-тысячной Document_РеализацияТоваровУслуг это 91 поле в
# 8 select-пачках ≈ 400 запросов ≈ ~50 минут ТОЛЬКО на заголовок — и
# большинство полей (доверенности, водитель/транспорт, ГИСМ, факторинг)
# для этого бизнеса нулевые. Здесь — сокращённый список полей ДЛЯ ЭТОГО
# ДОКУМЕНТА, чтобы уложиться в 1-2 select-пачки. Остальные объекты малы
# (до 7332 строк) и такого сокращения не требуют.
HEADER_FIELD_OVERRIDE: dict[str, list[str]] = {
    'Document_РеализацияТоваровУслуг': [
        'Ref_Key', 'Number', 'Date', 'Posted', 'DeletionMark', 'ВидОперации',
        'Организация_Key', 'Склад_Key', 'ПодразделениеОрганизации_Key',
        'Контрагент_Key', 'ДоговорКонтрагента_Key', 'ТипЦен_Key',
        'ВалютаДокумента_Key', 'КурсВзаиморасчетов', 'СуммаВключаетНДС',
        'СуммаДокумента', 'Ответственный_Key', 'Комментарий',
        'РучнаяКорректировка', 'ОтчетМаркетплейса_Key', 'Комиссионер_Key',
        'СчетНаОплатуПокупателю_Key', 'ЭлектроннаяТорговаяПлощадка',
    ],
}


def export_entity(entity: str, xml: str, guid_map: dict[str, str]):
    print(f'== {entity} ==')
    scalar, tabular = entity_fields(xml, entity)
    tabular = [t for t in tabular if t not in BARCODE_TABULAR_SKIP]
    key = key_field(xml, entity)

    fields = scalar
    if entity in HEADER_FIELD_OVERRIDE:
        fields = [f for f in HEADER_FIELD_OVERRIDE[entity] if f in scalar]
        dropped = len(scalar) - len(fields)
        print(f'  ! сокращённый набор полей заголовка: {len(fields)} из {len(scalar)} '
              f'(отброшено {dropped} технических/юридических полей — см. HEADER_FIELD_OVERRIDE в скрипте)')

    t0 = time.time()
    header_rows = fetch_all_wide(entity, fields, key, page=5000)
    print(f'  Заголовок: {len(header_rows)} строк, {round(time.time() - t0, 1)}с')

    wb = openpyxl.Workbook()
    wb.remove(wb.active)
    write_sheet(wb, 'Заголовок', header_rows, guid_map)

    for part in tabular:
        t0 = time.time()
        part_entity = f'{entity}_{part}'
        try:
            part_rows = fetch_all(part_entity, page=5000)
        except Exception as e:  # noqa: BLE001
            print(f'  {part}: ошибка ({e})', file=sys.stderr)
            continue
        print(f'  {part}: {len(part_rows)} строк, {round(time.time() - t0, 1)}с')
        write_sheet(wb, part, part_rows, guid_map)

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    out_path = OUT_DIR / f'{entity}.xlsx'
    wb.save(out_path)
    print(f'  -> {out_path}')


def main():
    entities = sys.argv[1:]
    if not entities:
        print('Использование: export_odata_bottling.py <Entity1> <Entity2> ...')
        sys.exit(1)
    xml = load_metadata()
    guid_map = build_guid_dict()
    for e in entities:
        export_entity(e, xml, guid_map)


if __name__ == '__main__':
    main()
