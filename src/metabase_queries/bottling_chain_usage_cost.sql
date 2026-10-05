-- Metabase: "Визуал - Bottling - Расход материалов в производство, по ценам закупки" (генерируется scripts/gen_bottling_chain_cards.py)
-- Те же строки, значения — расход × последняя цена закупки без НДС на дату расхода, ₽. Справочно: не учёт 1С.
-- Столбцы — месяцы 2026 + Итого; пустая ячейка — нет данных за месяц.
SELECT
    product AS "Продукция",
    material_category AS "Категория",
    round(nullIf(sumIf(v, month = toDate('2026-01-01')), 0), 0) AS "Янв-26",
    round(nullIf(sumIf(v, month = toDate('2026-02-01')), 0), 0) AS "Фев-26",
    round(nullIf(sumIf(v, month = toDate('2026-03-01')), 0), 0) AS "Мар-26",
    round(nullIf(sumIf(v, month = toDate('2026-04-01')), 0), 0) AS "Апр-26",
    round(nullIf(sumIf(v, month = toDate('2026-05-01')), 0), 0) AS "Май-26",
    round(nullIf(sumIf(v, month = toDate('2026-06-01')), 0), 0) AS "Июн-26",
    round(nullIf(sumIf(v, month = toDate('2026-07-01')), 0), 0) AS "Июл-26",
    round(nullIf(sumIf(v, month = toDate('2026-08-01')), 0), 0) AS "Авг-26",
    round(nullIf(sumIf(v, month = toDate('2026-09-01')), 0), 0) AS "Сен-26",
    round(nullIf(sumIf(v, month = toDate('2026-10-01')), 0), 0) AS "Окт-26",
    round(nullIf(sumIf(v, month = toDate('2026-11-01')), 0), 0) AS "Ноя-26",
    round(nullIf(sumIf(v, month = toDate('2026-12-01')), 0), 0) AS "Дек-26",
    round(nullIf(sum(v), 0), 0) AS "Итого"
FROM
(
    SELECT month, product, material_category, sum(cost_ref) AS v
    FROM bottling.chain_usage
    WHERE month >= '2026-01-01'
    GROUP BY month, product, material_category
)
GROUP BY product, material_category
ORDER BY product, material_category
