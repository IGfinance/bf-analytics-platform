-- Metabase: "Визуал - Bottling - Выпуск по отчётам производства"
-- Сколько штук выпущено, когда и сколько материалов в них вошло. Параметр {{month}}.
SELECT
    formatDateTime(o.date, '%Y-%m-%d')          AS "Дата",
    o.product                                    AS "Продукция",
    o.qty_out                                    AS "Выпущено, шт",
    round(u.cost_acc, 2)                         AS "Материалы по учёту, ₽",
    round(u.cost_acc / nullIf(o.qty_out, 0), 3)  AS "Материалы на шт, ₽",
    round(u.cost_buy, 2)                         AS "Материалы по ценам закупки, ₽ справочно"
FROM bottling.chain_output AS o
LEFT JOIN
(
    SELECT recorder, product, sum(cost) AS cost_acc, sum(cost_ref) AS cost_buy
    FROM bottling.chain_usage GROUP BY recorder, product
) AS u ON u.recorder = o.recorder AND u.product = o.product
WHERE o.month = toStartOfMonth(toDate({{month}}))
ORDER BY o.date, o.product
