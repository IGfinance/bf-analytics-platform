-- Metabase: "Визуал - Bottling - Заказы: себестоимость и маржа"
-- (дашборд "Дашборд - Bottling - Себестоимость"). Заказ = документ
-- реализации. Источник — VIEW bottling.cost_order_lines. Себестоимость —
-- РАСПРЕДЕЛЕНИЕ (см. bottling_cost_by_company.sql). ВАЖНО — лимит 2000
-- строк на native-запросы: показаны 2000 самых свежих заказов выбранного
-- периода. Фильтры: Компания / Группа / Период.
SELECT
    toDate(min(date)) AS "Дата",
    any(number) AS "Номер",
    any(counterparty) AS "Компания",
    round(sum(quantity)) AS "Количество",
    round(sum(revenue)) AS "Выручка",
    round(sum(cost_total)) AS "Себестоимость итого",
    round(sum(margin_total)) AS "Маржа",
    if(sum(revenue) != 0, round(100 * sum(margin_total) / sum(revenue), 1), 0) AS "Маржа, %"
FROM cost_order_lines
WHERE 1 = 1
    [[ AND {{company}} ]]
    [[ AND {{group}} ]]
    [[ AND {{period}} ]]
GROUP BY ref_key
ORDER BY min(date) DESC
LIMIT 2000
