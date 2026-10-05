-- Metabase: "Визуал - Bottling - Расход материалов в производство, количество" (генерируется scripts/gen_bottling_chain_cards.py)
-- Из чего произведено: строки — продукция и категория материала, значения — расход материала по отчётам производства (в единицах материала).
-- Столбцы — месяцы 2026 + Итого; пустая ячейка — нет данных за месяц.
SELECT
    product AS "Продукция",
    material_category AS "Категория",
    round(nullIf(sumIf(v, month = toDate('2026-01-01')), 0), 1) AS "Янв-26",
    round(nullIf(sumIf(v, month = toDate('2026-02-01')), 0), 1) AS "Фев-26",
    round(nullIf(sumIf(v, month = toDate('2026-03-01')), 0), 1) AS "Мар-26",
    round(nullIf(sumIf(v, month = toDate('2026-04-01')), 0), 1) AS "Апр-26",
    round(nullIf(sumIf(v, month = toDate('2026-05-01')), 0), 1) AS "Май-26",
    round(nullIf(sumIf(v, month = toDate('2026-06-01')), 0), 1) AS "Июн-26",
    round(nullIf(sumIf(v, month = toDate('2026-07-01')), 0), 1) AS "Июл-26",
    round(nullIf(sumIf(v, month = toDate('2026-08-01')), 0), 1) AS "Авг-26",
    round(nullIf(sumIf(v, month = toDate('2026-09-01')), 0), 1) AS "Сен-26",
    round(nullIf(sumIf(v, month = toDate('2026-10-01')), 0), 1) AS "Окт-26",
    round(nullIf(sumIf(v, month = toDate('2026-11-01')), 0), 1) AS "Ноя-26",
    round(nullIf(sumIf(v, month = toDate('2026-12-01')), 0), 1) AS "Дек-26",
    round(nullIf(sum(v), 0), 1) AS "Итого"
FROM
(
    SELECT month, product, material_category, sum(qty_used) AS v
    FROM bottling.chain_usage
    WHERE month >= '2026-01-01'
    GROUP BY month, product, material_category
)
GROUP BY product, material_category
ORDER BY product, material_category
