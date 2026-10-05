-- Metabase: "Визуал - Bottling - Цепочка по месяцам" (генерируется scripts/gen_bottling_chain_cards.py)
-- Материальная цепочка: закупка → расход в производство → продажа, остатки, проценты. Строки — показатели,
-- столбцы — месяцы 2026 + Итого. Пустые строки (Показатель = NULL) — цветные разделители (см. настройки карточки).
-- Материалы — Дт 20.01 / Кт 10.01 по учёту 1С. Остатки — из 1С (BalanceAndTurnovers) на конец месяца:
-- материалы = счёт 10.01, готовая продукция = счёт 43 по ПОЛНОЙ учётной себестоимости (не только материалы).
-- Месяц, не закрытый в 1С (сентябрь 2026), — остатки предварительные, расход материалов ещё не списан по стоимости.
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
               sum(bought) AS bought, sum(mat_booked) AS mat_booked, sum(mat_sold) AS mat_sold, sum(rev) AS rev,
               sum(sold_qty) AS sold_qty, sum(sold_known) AS sold_known,
               sum(bal_mat) AS bal_mat, sum(bal_goods) AS bal_goods
        FROM
        (
            SELECT month, sum(amount_net) AS bought, 0 AS mat_booked, 0 AS mat_sold, 0 AS rev, 0 AS sold_qty, 0 AS sold_known, 0 AS bal_mat, 0 AS bal_goods
            FROM bottling.purchases WHERE month >= '2026-01-01' GROUP BY month
            UNION ALL
            SELECT month, 0, sum(cost_material), 0, 0, 0, 0, 0, 0
            FROM bottling.chain_product_month WHERE month >= '2026-01-01' GROUP BY month
            UNION ALL
            SELECT month, 0, 0, sum(cost_material), sum(revenue), sum(quantity), sumIf(quantity, has_cost = 1), 0, 0
            FROM bottling.chain_sales WHERE month >= '2026-01-01' GROUP BY month
            UNION ALL
            SELECT month, 0, 0, 0, 0, 0, 0, sum(balance_materials), sum(balance_goods)
            FROM bottling.balances_month WHERE month >= '2026-01-01' GROUP BY month
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
    SELECT month, idx, [toNullable(bought), toNullable(mat_booked), toNullable(mat_sold), toNullable(rev), toNullable(NULL), toNullable(if(month = toDate('1970-01-01'), NULL, nullIf(bal_mat, 0))), toNullable(if(month = toDate('1970-01-01'), NULL, nullIf(bal_goods, 0))), toNullable(NULL), toNullable(100 * mat_sold / nullIf(rev, 0)), toNullable(100 * sold_known / nullIf(sold_qty, 0))][idx] AS v,
           ['Закуплено материалов, ₽', 'Материалы в выпуске по учёту, ₽', 'Материалы проданного по учёту, ₽', 'Выручка без НДС, ₽', NULL, 'Остатки материалов на конец месяца, ₽', 'Остатки готовой продукции на конец месяца, ₽, полная себестоимость по учёту', NULL, 'Материалы проданного по учёту, % от выручки без НДС', 'Продано с известной себестоимостью, % шт'] AS labels, [0, 0, 0, 0, 0, 0, 0, 0, 2, 2] AS kinds
    FROM base
    ARRAY JOIN range(1, 11) AS idx
)
GROUP BY idx, labels, kinds
ORDER BY idx
