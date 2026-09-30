#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Собирает выручку по месяцам из выгрузки OData
data-files/odata-bottling/Document_РеализацияТоваровУслуг.xlsx —
джойнит "Заголовок" (шапка продажи) с "Товары" (строки) по Ref_Key,
берёт только поля, которые попросил владелец, и строит:
  - лист "Продажи" — плоская объединённая таблица (шапка + строка товара);
    первые две колонки — ID продажи (Ref_Key, гарантированно уникален) и
    Номер документа (Number). Номер САМ ПО СЕБЕ не уникален — нумерация
    у этой базы сбрасывается (проверено 2026-09-29: 8531 номеров из 17044
    встречаются у 2+ разных документов, напр. "ПЛБП-002330" — у 8 разных
    продаж) — использовать его для склейки строк одной продажи МОЖНО
    только вместе с датой, а надёжно — только по Ref_Key.
  - лист "Сводная" — контрагент -> товар (сворачиваемая группировка) x месяц,
    значение = сумма продаж (поле "Сумма" из строки, БЕЗ НДС — это то,
    что лежит в исходной колонке)

Фильтр: берутся только ПРОВЕДЁННЫЕ документы (Posted = True) и без
пометки на удаление (DeletionMark = False) — черновики и будущие
непроведённые документы (видели 2026-12-31 с Posted=False) выручкой
не считаются.

Запуск:
    python3 scripts/build_realizacia_revenue.py
"""
from __future__ import annotations

import datetime as dt
from pathlib import Path

import openpyxl
from openpyxl.utils import get_column_letter

REPO = Path(__file__).resolve().parent.parent
SRC = REPO / 'data-files' / 'odata-bottling' / 'Document_РеализацияТоваровУслуг.xlsx'
OUT = REPO / 'data-files' / 'odata-bottling' / 'Выручка по месяцам — РеализацияТоваровУслуг.xlsx'

HEADER_COLS = [
    'Ref_Key', 'Number', 'Date', 'Контрагент (расшифровка)',
    'ДоговорКонтрагента_Key', 'ДоговорКонтрагента (расшифровка)',
    'ТипЦен_Key', 'ТипЦен (расшифровка)',
    'ВалютаДокумента_Key', 'ВалютаДокумента (расшифровка)',
    'КурсВзаиморасчетов', 'СуммаВключаетНДС', 'СуммаДокумента',
    'Ответственный_Key', 'Ответственный (расшифровка)',
    'Posted', 'DeletionMark',
]
LINE_COLS = [
    'Ref_Key', 'Номенклатура (расшифровка)', 'КоличествоМест',
    'ЕдиницаИзмерения_Key', 'ЕдиницаИзмерения (расшифровка)',
    'Коэффициент', 'Количество', 'Цена', 'Сумма', 'СтавкаНДС', 'СуммаНДС',
]


def read_sheet(path: Path, sheet: str, wanted: list[str]) -> list[dict]:
    wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
    ws = wb[sheet]
    rows_iter = ws.iter_rows(values_only=True)
    header = next(rows_iter)
    idx = {name: i for i, name in enumerate(header)}
    missing = [w for w in wanted if w not in idx]
    if missing:
        raise RuntimeError(f'{sheet}: нет колонок {missing}')
    out = []
    for r in rows_iter:
        out.append({w: r[idx[w]] for w in wanted})
    wb.close()
    return out


def main():
    print('Читаю "Заголовок"...')
    header_rows = read_sheet(SRC, 'Заголовок', HEADER_COLS)
    print(f'  {len(header_rows)} строк')

    header_by_ref = {}
    dropped_not_posted = 0
    dropped_deleted = 0
    for h in header_rows:
        if not h['Posted']:
            dropped_not_posted += 1
            continue
        if h['DeletionMark']:
            dropped_deleted += 1
            continue
        header_by_ref[h['Ref_Key']] = h
    print(f'  проведённых и не помеченных на удаление: {len(header_by_ref)} '
          f'(отброшено: не проведено {dropped_not_posted}, на удаление {dropped_deleted})')

    print('Читаю "Товары"...')
    line_rows = read_sheet(SRC, 'Товары', LINE_COLS)
    print(f'  {len(line_rows)} строк')

    combined = []
    orphan_lines = 0
    currencies = set()
    for line in line_rows:
        h = header_by_ref.get(line['Ref_Key'])
        if h is None:
            orphan_lines += 1
            continue
        date = h['Date']
        if isinstance(date, str):
            date = dt.datetime.fromisoformat(date)
        month = dt.date(date.year, date.month, 1) if date else None
        currencies.add(h['ВалютаДокумента (расшифровка)'])
        combined.append({
            'ID продажи (Ref_Key)': h['Ref_Key'],
            'Номер': h['Number'],
            'Дата': date,
            'Месяц': month,
            'Контрагент': h['Контрагент (расшифровка)'],
            'ДоговорКонтрагента': h['ДоговорКонтрагента (расшифровка)'],
            'ТипЦен': h['ТипЦен (расшифровка)'],
            'ВалютаДокумента': h['ВалютаДокумента (расшифровка)'],
            'КурсВзаиморасчетов': h['КурсВзаиморасчетов'],
            'СуммаВключаетНДС': h['СуммаВключаетНДС'],
            'СуммаДокумента': h['СуммаДокумента'],
            'Ответственный': h['Ответственный (расшифровка)'],
            'Номенклатура': line['Номенклатура (расшифровка)'],
            'КоличествоМест': line['КоличествоМест'],
            'ЕдиницаИзмерения': line['ЕдиницаИзмерения (расшифровка)'],
            'Коэффициент': line['Коэффициент'],
            'Количество': line['Количество'],
            'Цена': line['Цена'],
            'Сумма': line['Сумма'] or 0,
            'СтавкаНДС': line['СтавкаНДС'],
            'СуммаНДС': line['СуммаНДС'],
        })
    print(f'  сопоставлено с шапкой: {len(combined)} строк товаров '
          f'(без шапки/непроведённых: {orphan_lines})')
    print(f'  валюты в данных: {sorted(c for c in currencies if c)}')

    print(f'Пишу {OUT.name}...')
    write_output(combined)
    print('Готово:', OUT)


def write_output(combined: list[dict]):
    wb = openpyxl.Workbook()
    write_flat_sheet(wb.active, combined)
    write_pivot_sheet(wb.create_sheet('Сводная'), combined)
    OUT.parent.mkdir(parents=True, exist_ok=True)
    wb.save(OUT)


def write_flat_sheet(ws, combined: list[dict]):
    ws.title = 'Продажи'
    if not combined:
        ws.append(['(нет строк)'])
        return
    cols = list(combined[0].keys())
    ws.append(cols)
    for row in combined:
        ws.append([row[c] for c in cols])
    date_col = cols.index('Дата') + 1
    month_col = cols.index('Месяц') + 1
    for r in range(2, len(combined) + 2):
        ws.cell(r, date_col).number_format = 'DD.MM.YYYY'
        ws.cell(r, month_col).number_format = 'MMM YYYY'
    for i, c in enumerate(cols, start=1):
        ws.column_dimensions[get_column_letter(i)].width = max(len(c) + 2, 12)
    ws.freeze_panes = 'A2'


def write_pivot_sheet(ws, combined: list[dict]):
    months = sorted({r['Месяц'] for r in combined if r['Месяц']})
    agg: dict[tuple[str, str], dict] = {}
    company_total: dict[str, dict] = {}
    grand_total: dict = {}
    for r in combined:
        company = r['Контрагент'] or '(без контрагента)'
        product = r['Номенклатура'] or '(без номенклатуры)'
        m = r['Месяц']
        v = r['Сумма'] or 0
        agg.setdefault((company, product), {})[m] = agg.get((company, product), {}).get(m, 0) + v
        company_total.setdefault(company, {})[m] = company_total.get(company, {}).get(m, 0) + v
        grand_total[m] = grand_total.get(m, 0) + v

    # порядок компаний — по убыванию общей суммы за весь период
    companies = sorted(company_total.keys(),
                        key=lambda c: -sum(company_total[c].values()))

    header = ['Контрагент / Номенклатура'] + [m.strftime('%Y-%m') for m in months] + ['Итого']
    ws.append(header)
    ws.freeze_panes = 'B2'
    ws.sheet_properties.outlinePr.summaryBelow = False  # группа сворачивается ПОД своим заголовком

    def money(v):
        return round(v, 2) if v else 0

    row_i = 1
    # общий итог
    row_i += 1
    total_row = ['ИТОГО ПО ВСЕМ'] + [money(grand_total.get(m, 0)) for m in months]
    total_row.append(money(sum(grand_total.values())))
    ws.append(total_row)
    for c in ws[row_i]:
        c.font = c.font.copy(bold=True)

    for company in companies:
        row_i += 1
        ctot = company_total[company]
        row = [company] + [money(ctot.get(m, 0)) for m in months]
        row.append(money(sum(ctot.values())))
        ws.append(row)
        for c in ws[row_i]:
            c.font = c.font.copy(bold=True)
        ws.row_dimensions[row_i].outlineLevel = 0

        products = sorted(
            [p for (co, p) in agg if co == company],
            key=lambda p: -sum(agg[(company, p)].values()),
        )
        for product in products:
            row_i += 1
            ptot = agg[(company, product)]
            prow = ['    ' + product] + [money(ptot.get(m, 0)) for m in months]
            prow.append(money(sum(ptot.values())))
            ws.append(prow)
            ws.row_dimensions[row_i].outlineLevel = 1

    ws.column_dimensions['A'].width = 55
    for i in range(2, len(header) + 1):
        ws.column_dimensions[get_column_letter(i)].width = 14
        for r in range(2, row_i + 1):
            ws.cell(r, i).number_format = '#,##0'


if __name__ == '__main__':
    main()
