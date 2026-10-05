-- Metabase: "Визуал - Bottling - Цепочка по месяцам" (генерируется scripts/gen_bottling_chain_cards.py)
-- Материальная цепочка: закупка → расход в производство → выпуск → продажа. Строки — показатели,
-- столбцы — месяцы 2026 + Итого. Только материалы (Дт 20.01 / Кт 10.01).
-- «По учёту» — стоимость из проводок 1С; «по ценам закупки» — справочная оценка, в итоги не входит.
WITH
    (x -> if(x IS NULL, '',
        concat(if(x < 0, '-', ''),
            multiIf(abs(x) >= 1000000,
                        concat(toString(intDiv(toInt64(round(abs(x))), 1000000)), ' ', lpad(toString(intDiv(toInt64(round(abs(x))) % 1000000, 1000)), 3, '0'), ' ', lpad(toString(toInt64(round(abs(x))) % 1000), 3, '0')),
                    abs(x) >= 1000,
                        concat(toString(intDiv(toInt64(round(abs(x))), 1000)), ' ', lpad(toString(toInt64(round(abs(x))) % 1000), 3, '0')),
                    toString(toInt64(round(abs(x)))))))) AS fmt_int,
    (x -> if(x IS NULL, '', replaceOne(toString(round(x, 3)), '.', ','))) AS fmt_dec,
    (x -> if(x IS NULL, '', concat(replaceOne(if(position(toString(round(x, 1)), '.') = 0, concat(toString(round(x, 1)), '.0'), toString(round(x, 1))), '.', ','), ' %'))) AS fmt_pct,
    base AS (
        SELECT month,
               sum(bought) AS bought, sum(mat_booked) AS mat_booked, sum(mat_ref) AS mat_ref, sum(made) AS made,
               sum(sold_qty) AS sold_qty, sum(sold_known) AS sold_known, sum(rev) AS rev, sum(mat_sold) AS mat_sold
        FROM
        (
            SELECT month, sum(amount_net) AS bought, 0 AS mat_booked, 0 AS mat_ref, 0 AS made, 0 AS sold_qty, 0 AS sold_known, 0 AS rev, 0 AS mat_sold
            FROM bottling.purchases WHERE month >= '2026-01-01' GROUP BY month
            UNION ALL
            SELECT month, 0, sum(cost_material), sum(cost_material_ref), sum(qty_out), 0, 0, 0, 0
            FROM bottling.chain_product_month WHERE month >= '2026-01-01' GROUP BY month
            UNION ALL
            SELECT month, 0, 0, 0, 0, sum(quantity), sumIf(quantity, has_cost = 1), sum(revenue), sum(cost_material)
            FROM bottling.chain_sales WHERE month >= '2026-01-01' GROUP BY month
        )
        GROUP BY month WITH ROLLUP
    )
SELECT
    labels[idx] AS "Показатель",
    multiIf(kinds[idx] = 0, fmt_int(max(if(month = toDate('2026-01-01'), v, NULL))), kinds[idx] = 1, fmt_dec(max(if(month = toDate('2026-01-01'), v, NULL))), fmt_pct(max(if(month = toDate('2026-01-01'), v, NULL)))) AS "Янв-26",
    multiIf(kinds[idx] = 0, fmt_int(max(if(month = toDate('2026-02-01'), v, NULL))), kinds[idx] = 1, fmt_dec(max(if(month = toDate('2026-02-01'), v, NULL))), fmt_pct(max(if(month = toDate('2026-02-01'), v, NULL)))) AS "Фев-26",
    multiIf(kinds[idx] = 0, fmt_int(max(if(month = toDate('2026-03-01'), v, NULL))), kinds[idx] = 1, fmt_dec(max(if(month = toDate('2026-03-01'), v, NULL))), fmt_pct(max(if(month = toDate('2026-03-01'), v, NULL)))) AS "Мар-26",
    multiIf(kinds[idx] = 0, fmt_int(max(if(month = toDate('2026-04-01'), v, NULL))), kinds[idx] = 1, fmt_dec(max(if(month = toDate('2026-04-01'), v, NULL))), fmt_pct(max(if(month = toDate('2026-04-01'), v, NULL)))) AS "Апр-26",
    multiIf(kinds[idx] = 0, fmt_int(max(if(month = toDate('2026-05-01'), v, NULL))), kinds[idx] = 1, fmt_dec(max(if(month = toDate('2026-05-01'), v, NULL))), fmt_pct(max(if(month = toDate('2026-05-01'), v, NULL)))) AS "Май-26",
    multiIf(kinds[idx] = 0, fmt_int(max(if(month = toDate('2026-06-01'), v, NULL))), kinds[idx] = 1, fmt_dec(max(if(month = toDate('2026-06-01'), v, NULL))), fmt_pct(max(if(month = toDate('2026-06-01'), v, NULL)))) AS "Июн-26",
    multiIf(kinds[idx] = 0, fmt_int(max(if(month = toDate('2026-07-01'), v, NULL))), kinds[idx] = 1, fmt_dec(max(if(month = toDate('2026-07-01'), v, NULL))), fmt_pct(max(if(month = toDate('2026-07-01'), v, NULL)))) AS "Июл-26",
    multiIf(kinds[idx] = 0, fmt_int(max(if(month = toDate('2026-08-01'), v, NULL))), kinds[idx] = 1, fmt_dec(max(if(month = toDate('2026-08-01'), v, NULL))), fmt_pct(max(if(month = toDate('2026-08-01'), v, NULL)))) AS "Авг-26",
    multiIf(kinds[idx] = 0, fmt_int(max(if(month = toDate('2026-09-01'), v, NULL))), kinds[idx] = 1, fmt_dec(max(if(month = toDate('2026-09-01'), v, NULL))), fmt_pct(max(if(month = toDate('2026-09-01'), v, NULL)))) AS "Сен-26",
    multiIf(kinds[idx] = 0, fmt_int(max(if(month = toDate('2026-10-01'), v, NULL))), kinds[idx] = 1, fmt_dec(max(if(month = toDate('2026-10-01'), v, NULL))), fmt_pct(max(if(month = toDate('2026-10-01'), v, NULL)))) AS "Окт-26",
    multiIf(kinds[idx] = 0, fmt_int(max(if(month = toDate('2026-11-01'), v, NULL))), kinds[idx] = 1, fmt_dec(max(if(month = toDate('2026-11-01'), v, NULL))), fmt_pct(max(if(month = toDate('2026-11-01'), v, NULL)))) AS "Ноя-26",
    multiIf(kinds[idx] = 0, fmt_int(max(if(month = toDate('2026-12-01'), v, NULL))), kinds[idx] = 1, fmt_dec(max(if(month = toDate('2026-12-01'), v, NULL))), fmt_pct(max(if(month = toDate('2026-12-01'), v, NULL)))) AS "Дек-26",
    multiIf(kinds[idx] = 0, fmt_int(max(if(month = toDate('1970-01-01'), v, NULL))), kinds[idx] = 1, fmt_dec(max(if(month = toDate('1970-01-01'), v, NULL))), fmt_pct(max(if(month = toDate('1970-01-01'), v, NULL)))) AS "Итого"
FROM
(
    SELECT month, idx, [toNullable(bought), toNullable(mat_booked), toNullable(mat_ref), toNullable(made), toNullable(mat_booked / nullIf(made, 0)), toNullable(sold_qty), toNullable(rev), toNullable(mat_sold), toNullable(100 * mat_sold / nullIf(rev, 0)), toNullable(100 * sold_known / nullIf(sold_qty, 0))][idx] AS v,
           ['Закуплено материалов, ₽', 'Материалы в выпуске по учёту, ₽', 'Материалы в выпуске по ценам закупки, ₽ справочно', 'Выпущено, шт', 'Материалы на шт по учёту, ₽', 'Продано, шт', 'Выручка без НДС, ₽', 'Материалы проданного по учёту, ₽', 'Материалы, % от выручки', 'Продано с известной себестоимостью, % шт'] AS labels, [0, 0, 0, 0, 1, 0, 0, 0, 2, 2] AS kinds
    FROM base
    ARRAY JOIN range(1, 11) AS idx
)
GROUP BY idx, labels, kinds
ORDER BY idx
