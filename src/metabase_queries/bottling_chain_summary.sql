-- Metabase: "Визуал - Bottling - Цепочка по месяцам"
-- Материальная цепочка по месяцам: закупка → расход в производство → выпуск → продажа.
-- Источник — VIEW из src/schema_bottling_chain.sql. Только материалы (20.01/10.01), без ОПР и зарплаты.
-- «Материалы в выпуске» — стоимость по учёту 1С; «по ценам закупки» — справочная оценка, в итоги не входит.
WITH
    months AS (SELECT month FROM bottling.chain_product_month GROUP BY month),
    buy AS (SELECT month, sum(amount_net) AS bought FROM bottling.purchases GROUP BY month),
    prod AS (
        SELECT month, sum(qty_out) AS made, sum(cost_material) AS mat_booked, sum(cost_material_ref) AS mat_ref
        FROM bottling.chain_product_month GROUP BY month
    ),
    sold AS (
        SELECT month, sum(quantity) AS sold_qty, sumIf(quantity, has_cost = 1) AS sold_known,
               sum(revenue) AS rev, sum(cost_material) AS mat_sold, sum(cost_material_ref) AS mat_sold_ref
        FROM bottling.chain_sales WHERE month >= '2026-01-01' GROUP BY month
    )
SELECT
    formatDateTime(m.month, '%Y-%m') AS "Месяц",
    round(b.bought)                  AS "Закуплено материалов, ₽",
    round(p.mat_booked)              AS "Материалы в выпуске по учёту, ₽",
    round(p.mat_ref)                 AS "Материалы в выпуске по ценам закупки, ₽ справочно",
    round(p.made)                    AS "Выпущено, шт",
    round(p.mat_booked / nullIf(p.made, 0), 3) AS "Материалы на шт по учёту, ₽",
    round(s.sold_qty)                AS "Продано, шт",
    round(s.rev)                     AS "Выручка без НДС, ₽",
    round(s.mat_sold)                AS "Материалы проданного по учёту, ₽",
    round(s.mat_sold / nullIf(s.rev, 0) * 100, 1) AS "Материалы, % от выручки",
    round(s.sold_known / nullIf(s.sold_qty, 0) * 100, 1) AS "Продано с известной себестоимостью, % шт"
FROM months AS m
LEFT JOIN buy  AS b ON b.month = m.month
LEFT JOIN prod AS p ON p.month = m.month
LEFT JOIN sold AS s ON s.month = m.month
ORDER BY m.month
