-- Metabase: "Визуал - Bottling - Продажи с материальной себестоимостью" (генерируется scripts/gen_bottling_chain_cards.py)
-- Строки — компания (покупатель) и продукция; под продукцией: Количество / Цена в документе / Выручка без НДС /
-- Материалы по учёту / Материалы % от выручки. Столбцы — месяцы 2026 + Итого.
-- Цена в документе — средневзвешенная по количеству, как в документе реализации. Материалы — ставка месяца
-- (см. bottling.chain_sales): 0, если в месяце продажи этой продукции не выпускали или 1С не списал стоимость.
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
    agg AS (
        SELECT counterparty AS company, product, month,
               sum(quantity) AS q, sum(price * quantity) AS pq, sum(revenue) AS rev, sum(cost_material) AS mat
        FROM bottling.chain_sales WHERE month >= '2026-01-01'
        GROUP BY company, product, month WITH ROLLUP
        HAVING product != ''
    ),
    ranked AS (
        SELECT *,
               max(if(month = toDate('1970-01-01'), rev, NULL)) OVER (PARTITION BY company, product) AS tot_pair,
               sum(if(month = toDate('1970-01-01'), rev, 0)) OVER (PARTITION BY company) AS tot_company
        FROM agg
    )
SELECT
    if(k = 1, company, '') AS "Компания",
    if(k = 1, product, '') AS "Продукция",
    ['Количество', 'Цена в документе, ₽', 'Выручка без НДС, ₽', 'Материалы по учёту, ₽', 'Материалы, % от выручки'][k] AS "Показатель",
    multiIf(k = 1, fmt_int(max(if(month = toDate('2026-01-01'), q, NULL))), k = 2, fmt_dec(max(if(month = toDate('2026-01-01'), pq / nullIf(q, 0), NULL))), k = 3, fmt_int(max(if(month = toDate('2026-01-01'), rev, NULL))), k = 4, fmt_int(max(if(month = toDate('2026-01-01'), mat, NULL))), fmt_pct(max(if(month = toDate('2026-01-01'), 100 * mat / nullIf(rev, 0), NULL)))) AS "Янв-26",
    multiIf(k = 1, fmt_int(max(if(month = toDate('2026-02-01'), q, NULL))), k = 2, fmt_dec(max(if(month = toDate('2026-02-01'), pq / nullIf(q, 0), NULL))), k = 3, fmt_int(max(if(month = toDate('2026-02-01'), rev, NULL))), k = 4, fmt_int(max(if(month = toDate('2026-02-01'), mat, NULL))), fmt_pct(max(if(month = toDate('2026-02-01'), 100 * mat / nullIf(rev, 0), NULL)))) AS "Фев-26",
    multiIf(k = 1, fmt_int(max(if(month = toDate('2026-03-01'), q, NULL))), k = 2, fmt_dec(max(if(month = toDate('2026-03-01'), pq / nullIf(q, 0), NULL))), k = 3, fmt_int(max(if(month = toDate('2026-03-01'), rev, NULL))), k = 4, fmt_int(max(if(month = toDate('2026-03-01'), mat, NULL))), fmt_pct(max(if(month = toDate('2026-03-01'), 100 * mat / nullIf(rev, 0), NULL)))) AS "Мар-26",
    multiIf(k = 1, fmt_int(max(if(month = toDate('2026-04-01'), q, NULL))), k = 2, fmt_dec(max(if(month = toDate('2026-04-01'), pq / nullIf(q, 0), NULL))), k = 3, fmt_int(max(if(month = toDate('2026-04-01'), rev, NULL))), k = 4, fmt_int(max(if(month = toDate('2026-04-01'), mat, NULL))), fmt_pct(max(if(month = toDate('2026-04-01'), 100 * mat / nullIf(rev, 0), NULL)))) AS "Апр-26",
    multiIf(k = 1, fmt_int(max(if(month = toDate('2026-05-01'), q, NULL))), k = 2, fmt_dec(max(if(month = toDate('2026-05-01'), pq / nullIf(q, 0), NULL))), k = 3, fmt_int(max(if(month = toDate('2026-05-01'), rev, NULL))), k = 4, fmt_int(max(if(month = toDate('2026-05-01'), mat, NULL))), fmt_pct(max(if(month = toDate('2026-05-01'), 100 * mat / nullIf(rev, 0), NULL)))) AS "Май-26",
    multiIf(k = 1, fmt_int(max(if(month = toDate('2026-06-01'), q, NULL))), k = 2, fmt_dec(max(if(month = toDate('2026-06-01'), pq / nullIf(q, 0), NULL))), k = 3, fmt_int(max(if(month = toDate('2026-06-01'), rev, NULL))), k = 4, fmt_int(max(if(month = toDate('2026-06-01'), mat, NULL))), fmt_pct(max(if(month = toDate('2026-06-01'), 100 * mat / nullIf(rev, 0), NULL)))) AS "Июн-26",
    multiIf(k = 1, fmt_int(max(if(month = toDate('2026-07-01'), q, NULL))), k = 2, fmt_dec(max(if(month = toDate('2026-07-01'), pq / nullIf(q, 0), NULL))), k = 3, fmt_int(max(if(month = toDate('2026-07-01'), rev, NULL))), k = 4, fmt_int(max(if(month = toDate('2026-07-01'), mat, NULL))), fmt_pct(max(if(month = toDate('2026-07-01'), 100 * mat / nullIf(rev, 0), NULL)))) AS "Июл-26",
    multiIf(k = 1, fmt_int(max(if(month = toDate('2026-08-01'), q, NULL))), k = 2, fmt_dec(max(if(month = toDate('2026-08-01'), pq / nullIf(q, 0), NULL))), k = 3, fmt_int(max(if(month = toDate('2026-08-01'), rev, NULL))), k = 4, fmt_int(max(if(month = toDate('2026-08-01'), mat, NULL))), fmt_pct(max(if(month = toDate('2026-08-01'), 100 * mat / nullIf(rev, 0), NULL)))) AS "Авг-26",
    multiIf(k = 1, fmt_int(max(if(month = toDate('2026-09-01'), q, NULL))), k = 2, fmt_dec(max(if(month = toDate('2026-09-01'), pq / nullIf(q, 0), NULL))), k = 3, fmt_int(max(if(month = toDate('2026-09-01'), rev, NULL))), k = 4, fmt_int(max(if(month = toDate('2026-09-01'), mat, NULL))), fmt_pct(max(if(month = toDate('2026-09-01'), 100 * mat / nullIf(rev, 0), NULL)))) AS "Сен-26",
    multiIf(k = 1, fmt_int(max(if(month = toDate('2026-10-01'), q, NULL))), k = 2, fmt_dec(max(if(month = toDate('2026-10-01'), pq / nullIf(q, 0), NULL))), k = 3, fmt_int(max(if(month = toDate('2026-10-01'), rev, NULL))), k = 4, fmt_int(max(if(month = toDate('2026-10-01'), mat, NULL))), fmt_pct(max(if(month = toDate('2026-10-01'), 100 * mat / nullIf(rev, 0), NULL)))) AS "Окт-26",
    multiIf(k = 1, fmt_int(max(if(month = toDate('2026-11-01'), q, NULL))), k = 2, fmt_dec(max(if(month = toDate('2026-11-01'), pq / nullIf(q, 0), NULL))), k = 3, fmt_int(max(if(month = toDate('2026-11-01'), rev, NULL))), k = 4, fmt_int(max(if(month = toDate('2026-11-01'), mat, NULL))), fmt_pct(max(if(month = toDate('2026-11-01'), 100 * mat / nullIf(rev, 0), NULL)))) AS "Ноя-26",
    multiIf(k = 1, fmt_int(max(if(month = toDate('2026-12-01'), q, NULL))), k = 2, fmt_dec(max(if(month = toDate('2026-12-01'), pq / nullIf(q, 0), NULL))), k = 3, fmt_int(max(if(month = toDate('2026-12-01'), rev, NULL))), k = 4, fmt_int(max(if(month = toDate('2026-12-01'), mat, NULL))), fmt_pct(max(if(month = toDate('2026-12-01'), 100 * mat / nullIf(rev, 0), NULL)))) AS "Дек-26",
    multiIf(k = 1, fmt_int(max(if(month = toDate('1970-01-01'), q, NULL))), k = 2, fmt_dec(max(if(month = toDate('1970-01-01'), pq / nullIf(q, 0), NULL))), k = 3, fmt_int(max(if(month = toDate('1970-01-01'), rev, NULL))), k = 4, fmt_int(max(if(month = toDate('1970-01-01'), mat, NULL))), fmt_pct(max(if(month = toDate('1970-01-01'), 100 * mat / nullIf(rev, 0), NULL)))) AS "Итого"
FROM ranked
ARRAY JOIN [1, 2, 3, 4, 5] AS k
GROUP BY company, product, tot_pair, tot_company, k
ORDER BY tot_company DESC, company, tot_pair DESC, product, k
