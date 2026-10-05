-- Metabase: "Визуал - Bottling - Продажи с материальной себестоимостью"
-- Сколько продано, кому, когда, по какой цене и с какой материальной себестоимостью (ставка месяца). Параметр {{month}}.
SELECT
    formatDateTime(date, '%Y-%m-%d')         AS "Дата",
    counterparty                             AS "Покупатель",
    product                                  AS "Продукция",
    quantity                                 AS "Количество",
    unit                                     AS "Ед.",
    price                                    AS "Цена в документе, ₽",
    round(revenue, 2)                        AS "Выручка без НДС, ₽",
    round(unit_material_cost, 3)             AS "Материалы на шт по учёту, ₽",
    round(cost_material, 2)                  AS "Материалы по учёту, ₽",
    round(cost_material / nullIf(revenue, 0) * 100, 1) AS "Материалы, % от выручки",
    if(has_cost = 1, '', 'нет выпуска в месяце продажи')  AS "Пометка"
FROM bottling.chain_sales
WHERE month = toStartOfMonth(toDate({{month}}))
ORDER BY date, counterparty, product
