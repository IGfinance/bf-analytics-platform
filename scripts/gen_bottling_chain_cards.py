#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Генератор SQL карточек дашборда «Bottling — Материальная цепочка» (месяцы — столбцы).
Пишет src/metabase_queries/bottling_chain_*.sql. Столбцы привязаны к ГОДУ (YEAR):
в начале года поменяйте YEAR и перегенерируйте, затем обновите карточки в Metabase.

    python3 scripts/gen_bottling_chain_cards.py [--year 2026]
"""
import argparse
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / 'src' / 'metabase_queries'
RU = ['Янв', 'Фев', 'Мар', 'Апр', 'Май', 'Июн', 'Июл', 'Авг', 'Сен', 'Окт', 'Ноя', 'Дек']
TOTAL = "toDate('1970-01-01')"   # метка итоговой строки ROLLUP

# Форматирование в текст (рубли/штуки с пробелами, цена и % с запятой); NULL -> пустая ячейка
FMT = """WITH
    (x -> if(x IS NULL, '',
        concat(if(x < 0, '-', ''),
            multiIf(abs(x) >= 1000000,
                        concat(toString(intDiv(toInt64(round(abs(x))), 1000000)), ' ', lpad(toString(intDiv(toInt64(round(abs(x))) % 1000000, 1000)), 3, '0'), ' ', lpad(toString(toInt64(round(abs(x))) % 1000), 3, '0')),
                    abs(x) >= 1000,
                        concat(toString(intDiv(toInt64(round(abs(x))), 1000)), ' ', lpad(toString(toInt64(round(abs(x))) % 1000), 3, '0')),
                    toString(toInt64(round(abs(x)))))))) AS fmt_int,
    (x -> if(x IS NULL, '', replaceOne(toString(round(x, 3)), '.', ','))) AS fmt_dec,
    (x -> if(x IS NULL, '', concat(replaceOne(if(position(toString(round(x, 1)), '.') = 0, concat(toString(round(x, 1)), '.0'), toString(round(x, 1))), '.', ','), ' %'))) AS fmt_pct"""


def mcond(year, i):
    return "month = toDate('%d-%02d-01')" % (year, i)


def mcols(year, expr):
    """Столбцы по месяцам + Итого; expr(cond) -> SQL значения для условия по месяцу."""
    cols = []
    for i, name in enumerate(RU, 1):
        cols.append('    %s AS "%s-%s"' % (expr(mcond(year, i)), name, str(year)[2:]))
    cols.append('    %s AS "Итого"' % expr('month = ' + TOTAL))
    return ',\n'.join(cols)


def card_chain(year):
    """1. Цепочка по месяцам: строки — показатели, столбцы — месяцы."""
    metrics = [  # (подпись, формула по компонентам, вид 0=целое 1=3 знака 2=%)
        ('Закуплено материалов, ₽', 'bought', 0),
        ('Материалы в выпуске по учёту, ₽', 'mat_booked', 0),
        ('Материалы в выпуске по ценам закупки, ₽ справочно', 'mat_ref', 0),
        ('Выпущено, шт', 'made', 0),
        ('Материалы на шт по учёту, ₽', 'mat_booked / nullIf(made, 0)', 1),
        ('Продано, шт', 'sold_qty', 0),
        ('Выручка без НДС, ₽', 'rev', 0),
        ('Материалы проданного по учёту, ₽', 'mat_sold', 0),
        ('Материалы, % от выручки', '100 * mat_sold / nullIf(rev, 0)', 2),
        ('Продано с известной себестоимостью, % шт', '100 * sold_known / nullIf(sold_qty, 0)', 2),
    ]
    vals = ', '.join(f'toNullable({f})' for _, f, _ in metrics)
    labels = ', '.join(f"'{l}'" for l, _, _ in metrics)
    kinds = ', '.join(str(k) for _, _, k in metrics)

    def expr(cond):
        return (f'multiIf(kinds[idx] = 0, fmt_int(max(if({cond}, v, NULL))), '
                f'kinds[idx] = 1, fmt_dec(max(if({cond}, v, NULL))), fmt_pct(max(if({cond}, v, NULL))))')
    return f"""-- Metabase: "Визуал - Bottling - Цепочка по месяцам" (генерируется scripts/gen_bottling_chain_cards.py)
-- Материальная цепочка: закупка → расход в производство → выпуск → продажа. Строки — показатели,
-- столбцы — месяцы {year} + Итого. Только материалы (Дт 20.01 / Кт 10.01).
-- «По учёту» — стоимость из проводок 1С; «по ценам закупки» — справочная оценка, в итоги не входит.
{FMT},
    base AS (
        SELECT month,
               sum(bought) AS bought, sum(mat_booked) AS mat_booked, sum(mat_ref) AS mat_ref, sum(made) AS made,
               sum(sold_qty) AS sold_qty, sum(sold_known) AS sold_known, sum(rev) AS rev, sum(mat_sold) AS mat_sold
        FROM
        (
            SELECT month, sum(amount_net) AS bought, 0 AS mat_booked, 0 AS mat_ref, 0 AS made, 0 AS sold_qty, 0 AS sold_known, 0 AS rev, 0 AS mat_sold
            FROM bottling.purchases WHERE month >= '{year}-01-01' GROUP BY month
            UNION ALL
            SELECT month, 0, sum(cost_material), sum(cost_material_ref), sum(qty_out), 0, 0, 0, 0
            FROM bottling.chain_product_month WHERE month >= '{year}-01-01' GROUP BY month
            UNION ALL
            SELECT month, 0, 0, 0, 0, sum(quantity), sumIf(quantity, has_cost = 1), sum(revenue), sum(cost_material)
            FROM bottling.chain_sales WHERE month >= '{year}-01-01' GROUP BY month
        )
        GROUP BY month WITH ROLLUP
    )
SELECT
    labels[idx] AS "Показатель",
{mcols(year, expr)}
FROM
(
    SELECT month, idx, [{vals}][idx] AS v,
           [{labels}] AS labels, [{kinds}] AS kinds
    FROM base
    ARRAY JOIN range(1, {len(metrics) + 1}) AS idx
)
GROUP BY idx, labels, kinds
ORDER BY idx
"""


def card_purchases(year):
    """3. Закупки: строки — материал × (Кол-во / Цена за ед. / Сумма), столбцы — месяцы."""
    def expr(cond):
        return (f'multiIf(k = 1, fmt_int(max(if({cond}, q, NULL))), '
                f'k = 2, fmt_dec(max(if({cond}, a / nullIf(q, 0), NULL))), '
                f'fmt_int(max(if({cond}, a, NULL))))')
    return f"""-- Metabase: "Визуал - Bottling - Закупки материалов" (генерируется scripts/gen_bottling_chain_cards.py)
-- Строки — материал; под ним Количество / Цена за ед. (без НДС, средняя взвешенная) / Сумма без НДС;
-- столбцы — месяцы {year} + Итого. Закупки — Document_ПоступлениеТоваровУслуг, счёт учёта 10.01.
-- Строки с подозрительной ценой (price_ok = 0, ошибка единицы в 1С) остаются в количестве и сумме.
{FMT},
    agg AS (
        SELECT nomenclature AS mat, any(unit) AS unit, month, sum(quantity) AS q, sum(amount_net) AS a
        FROM bottling.purchases WHERE month >= '{year}-01-01'
        GROUP BY mat, month WITH ROLLUP
        HAVING mat != ''
    ),
    ranked AS (
        SELECT *, max(if(month = {TOTAL}, a, NULL)) OVER (PARTITION BY mat) AS tot
        FROM agg
    )
SELECT
    if(k = 1, mat, '') AS "Материал",
    if(k = 1, unit, '') AS "Ед.",
    ['Количество', 'Цена за ед., ₽', 'Сумма, ₽'][k] AS "Показатель",
{mcols(year, expr)}
FROM ranked
ARRAY JOIN [1, 2, 3] AS k
GROUP BY mat, unit, tot, k
ORDER BY tot DESC, mat, k
"""


def card_matrix(title, comment, source, rowexpr, valexpr, year, rows_cols, filt='', total=False, rounding=None):
    """Числовая матрица: строки rows_cols (список (sql, подпись)), столбцы — месяцы + Итого."""
    r = rounding
    def sel(c, n):
        e = ("if(%s = '', 'ИТОГО', %s)" % (c, c)) if total else c
        return '    %s AS "%s"' % (e, n)
    sel_rows = ',\n'.join(sel(c, n) for c, n in rows_cols)
    grp = ', '.join(c for c, _ in rows_cols)

    def cell(cond):
        v = f'nullIf(sumIf(v, {cond}), 0)'
        return f'round({v}, {r})' if r is not None else v
    cols = []
    for i, name in enumerate(RU, 1):
        cols.append('    %s AS "%s-%s"' % (cell(mcond(year, i)), name, str(year)[2:]))
    tot = ('round(nullIf(sum(v), 0), %d)' % r) if r is not None else 'nullIf(sum(v), 0)'
    cols.append('    %s AS "Итого"' % tot)
    rollup = ' WITH ROLLUP' if total else ''
    order = f"ORDER BY {rows_cols[0][0]} = '', sum(v) DESC" if total else f'ORDER BY {grp}'
    return f"""-- Metabase: "{title}" (генерируется scripts/gen_bottling_chain_cards.py)
-- {comment}
-- Столбцы — месяцы {year} + Итого; пустая ячейка — нет данных за месяц.
SELECT
{sel_rows},
{chr(10).join(c + ',' for c in cols[:-1])}
{cols[-1]}
FROM
(
    SELECT month, {rowexpr}, {valexpr} AS v
    FROM {source}
    WHERE month >= '{year}-01-01'{filt}
    GROUP BY month, {grp}
)
GROUP BY {grp}{rollup}
{order}
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--year', type=int, default=2026)
    y = ap.parse_args().year
    files = {
        'summary': card_chain(y),
        'purchases': card_purchases(y),
        'usage_qty': card_matrix(
            'Визуал - Bottling - Расход материалов в производство, количество',
            'Из чего произведено: строки — продукция и категория материала, значения — расход материала по отчётам производства (в единицах материала).',
            'bottling.chain_usage', 'product, material_category', 'sum(qty_used)', y,
            [('product', 'Продукция'), ('material_category', 'Категория')], rounding=1),
        'usage_cost': card_matrix(
            'Визуал - Bottling - Расход материалов в производство, по ценам закупки',
            'Те же строки, значения — расход × последняя цена закупки без НДС на дату расхода, ₽. Справочно: не учёт 1С.',
            'bottling.chain_usage', 'product, material_category', 'sum(cost_ref)', y,
            [('product', 'Продукция'), ('material_category', 'Категория')], rounding=0),
        'output_qty': card_matrix(
            'Визуал - Bottling - Выпуск, штук',
            'Выпуск готовой продукции по отчётам производства, шт.',
            'bottling.chain_product_month', 'product', 'sum(qty_out)', y,
            [('product', 'Продукция')], total=True, rounding=0),
        'output_cost_ref': card_matrix(
            'Визуал - Bottling - Выпуск, материалы по ценам закупки',
            'Материалы в выпущенной продукции по ценам закупки без НДС, ₽. Справочно: не учёт 1С.',
            'bottling.chain_product_month', 'product', 'sum(cost_material_ref)', y,
            [('product', 'Продукция')], total=True, rounding=0),
        'output_cost': card_matrix(
            'Визуал - Bottling - Выпуск, материалы по учёту',
            'Материалы в выпущенной продукции по учёту 1С (ставка материала в месяце), ₽. Ноль — 1С стоимость не списала.',
            'bottling.chain_product_month', 'product', 'sum(cost_material)', y,
            [('product', 'Продукция')], total=True, rounding=0),
        'sales_qty': card_matrix(
            'Визуал - Bottling - Продажи, штук',
            'Продано по реализациям, количество в единицах документа (в основном шт).',
            'bottling.chain_sales', 'product', 'sum(quantity)', y,
            [('product', 'Продукция')], total=True, rounding=0),
    }
    for key, sql in files.items():
        (OUT / f'bottling_chain_{key}.sql').write_text(sql, encoding='utf-8')
        print('written', key)


if __name__ == '__main__':
    main()
