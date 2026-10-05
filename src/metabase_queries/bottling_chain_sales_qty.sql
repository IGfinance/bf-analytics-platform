-- Metabase: "Визуал - Bottling - Продажи, штук" (генерируется scripts/gen_bottling_chain_cards.py)
-- Продано по реализациям, количество в единицах документа (в основном шт).
-- Столбцы — месяцы 2026 + Итого; пустая ячейка — нет данных за месяц.
SELECT
    if(product = '', 'ИТОГО', product) AS "Продукция",
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
    SELECT month, product, sum(quantity) AS v
    FROM bottling.chain_sales
    WHERE month >= '2026-01-01'
    GROUP BY month, product
)
GROUP BY product WITH ROLLUP
ORDER BY product = '', sum(v) DESC
