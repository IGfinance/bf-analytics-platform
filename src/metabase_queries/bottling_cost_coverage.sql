-- Metabase: "Визуал - Bottling - Покрытие себестоимости по группам"
-- (дашборд "Дашборд - Bottling - Себестоимость"). Честные пробелы: по
-- каждой группе и месяцу — проведённая себестоимость (Дт 90.02.1),
-- проданное количество, ставка ₽/шт, статус. "себестоимость без продаж"
-- — сумма не привязана к группе продаж и уходит в пул месяца;
-- "продажи без себестоимости" — у группы в месяце нет проводок (обычно
-- месяц ещё не закрыт). Источник — VIEW bottling.cost_rate_month.
-- Фильтры: Группа / Период.
SELECT
    toString(month) AS "Месяц",
    nomenclature_group AS "Группа",
    round(cogs) AS "Себестоимость (90.02.1)",
    round(qty_sold) AS "Продано, шт",
    round(revenue) AS "Выручка",
    round(rate_per_unit, 2) AS "Ставка, ₽/шт",
    status AS "Статус",
    if(month_closed = 1, 'да', 'нет') AS "Месяц закрыт"
FROM cost_rate_month
WHERE (cogs != 0 OR qty_sold != 0)
    [[ AND {{group}} ]]
    [[ AND {{period}} ]]
ORDER BY month DESC, abs(cogs) DESC
