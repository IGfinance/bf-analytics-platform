-- Metabase: "Визуал - Bottling - Расход материалов на штуку, по учёту" (генерируется scripts/gen_bottling_chain_cards.py)
-- Как списано в учёте 1С (ставка материала в месяце, регламентная операция); 0 — 1С стоимость не списала.
-- Строки — продукция и категория материала; значение — рубли материалов на 1 выпущенную штуку продукции
-- (рубли расхода категории за месяц / выпуск продукции за месяц). Итого — за весь период.
-- Столбцы — месяцы 2026; пустая ячейка — нет расхода или выпуска в месяце.
SELECT
    product AS "Продукция",
    material_category AS "Категория",
    round(nullIf(sumIf(cst, month = toDate('2026-01-01')), 0) / nullIf(sumIf(qty, month = toDate('2026-01-01')), 0), 3) AS "Янв-26",
    round(nullIf(sumIf(cst, month = toDate('2026-02-01')), 0) / nullIf(sumIf(qty, month = toDate('2026-02-01')), 0), 3) AS "Фев-26",
    round(nullIf(sumIf(cst, month = toDate('2026-03-01')), 0) / nullIf(sumIf(qty, month = toDate('2026-03-01')), 0), 3) AS "Мар-26",
    round(nullIf(sumIf(cst, month = toDate('2026-04-01')), 0) / nullIf(sumIf(qty, month = toDate('2026-04-01')), 0), 3) AS "Апр-26",
    round(nullIf(sumIf(cst, month = toDate('2026-05-01')), 0) / nullIf(sumIf(qty, month = toDate('2026-05-01')), 0), 3) AS "Май-26",
    round(nullIf(sumIf(cst, month = toDate('2026-06-01')), 0) / nullIf(sumIf(qty, month = toDate('2026-06-01')), 0), 3) AS "Июн-26",
    round(nullIf(sumIf(cst, month = toDate('2026-07-01')), 0) / nullIf(sumIf(qty, month = toDate('2026-07-01')), 0), 3) AS "Июл-26",
    round(nullIf(sumIf(cst, month = toDate('2026-08-01')), 0) / nullIf(sumIf(qty, month = toDate('2026-08-01')), 0), 3) AS "Авг-26",
    round(nullIf(sumIf(cst, month = toDate('2026-09-01')), 0) / nullIf(sumIf(qty, month = toDate('2026-09-01')), 0), 3) AS "Сен-26",
    round(nullIf(sumIf(cst, month = toDate('2026-10-01')), 0) / nullIf(sumIf(qty, month = toDate('2026-10-01')), 0), 3) AS "Окт-26",
    round(nullIf(sumIf(cst, month = toDate('2026-11-01')), 0) / nullIf(sumIf(qty, month = toDate('2026-11-01')), 0), 3) AS "Ноя-26",
    round(nullIf(sumIf(cst, month = toDate('2026-12-01')), 0) / nullIf(sumIf(qty, month = toDate('2026-12-01')), 0), 3) AS "Дек-26",
    round(nullIf(sum(cst), 0) / nullIf(sum(qty), 0), 3) AS "Итого"
FROM
(
    SELECT u.month AS month, u.product AS product, u.material_category AS material_category,
           u.cst AS cst, o.qty_out AS qty
    FROM
    (
        SELECT month, product, material_category, sum(cost) AS cst
        FROM bottling.chain_usage WHERE month >= '2026-01-01'
        GROUP BY month, product, material_category
    ) AS u
    LEFT JOIN (SELECT month, product, sum(qty_out) AS qty_out FROM bottling.chain_output GROUP BY month, product) AS o
        ON o.month = u.month AND o.product = u.product
)
GROUP BY product, material_category
ORDER BY product, material_category
