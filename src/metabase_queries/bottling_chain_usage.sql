-- Metabase: "Визуал - Bottling - Расход материалов в производство"
-- Из чего произведено: продукция × материал за месяц, расход, ставка учёта и справочная цена закупки. Параметр {{month}}.
SELECT
    product                                  AS "Продукция",
    material_category                        AS "Категория",
    material                                 AS "Материал",
    round(sum(qty_used), 1)                  AS "Расход, шт",
    formatDateTime(min(date), '%Y-%m-%d')    AS "Первое списание",
    formatDateTime(max(date), '%Y-%m-%d')    AS "Последнее списание",
    round(sum(cost), 2)                      AS "Стоимость по учёту, ₽",
    round(sum(cost) / nullIf(sum(qty_used), 0), 3) AS "Ставка учёта, ₽",
    round(sum(cost_ref), 2)                  AS "Стоимость по ценам закупки, ₽ справочно",
    round(sum(cost_ref) / nullIf(sum(qty_used), 0), 3) AS "Цена закупки, ₽"
FROM bottling.chain_usage
WHERE month = toStartOfMonth(toDate({{month}}))
GROUP BY product, material_category, material
ORDER BY product, sum(cost) DESC, sum(cost_ref) DESC
