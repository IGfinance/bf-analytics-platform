-- Metabase: "Визуал - Bottling - Маржа по компаниям" (дашборд
-- "Дашборд - Bottling - Себестоимость"). Компания: выручка, себестоимость
-- (по ставке группы + доля пула месяца), маржа, маржа %. Источник — VIEW
-- bottling.cost_order_lines. Себестоимость — РАСПРЕДЕЛЕНИЕ итога 90.02.1
-- (ставка группы в месяце × количество; пул месяца — по выручке), не
-- фактическая себестоимость конкретной отгрузки. Фильтры: Компания /
-- Группа / Период.
SELECT
    counterparty AS "Компания",
    round(sum(revenue)) AS "Выручка",
    round(sum(cost)) AS "Себестоимость по группе",
    round(sum(cost_pool)) AS "Доля пула месяца",
    round(sum(cost_total)) AS "Себестоимость итого",
    round(sum(margin_total)) AS "Маржа",
    round(100 * sum(margin_total) / sum(revenue), 1) AS "Маржа, %"
FROM cost_order_lines
WHERE 1 = 1
    [[ AND {{company}} ]]
    [[ AND {{group}} ]]
    [[ AND {{period}} ]]
GROUP BY counterparty
HAVING sum(revenue) != 0
ORDER BY sum(revenue) DESC
