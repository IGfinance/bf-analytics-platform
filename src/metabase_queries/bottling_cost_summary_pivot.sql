-- Metabase: "Визуал - Bottling - Себестоимость по месяцам" (дашборд
-- "Дашборд - Bottling - Себестоимость"). Кросс-таб: строки — показатель
-- (Выручка, слои себестоимости, Себестоимость итого, Маржа), столбцы —
-- месяц + "Итого". Источник — VIEW bottling.cost_summary_long (см.
-- src/schema_bottling_cost.sql). Слои — РАСПРЕДЕЛЕНИЕ итога 90.02.1 по
-- структуре выпуска месяца (не факт); "Не привязана к группе (пул
-- месяца)" — себестоимость групп без продаж в месяце, разложенная по
-- выручке. Фильтры: Компания / Группа / Период (field filter). Кросс-таб
-- на table.pivot (не серверный pivot — на native SQL он не работает):
-- порядок столбцов задаёт первая строка результата, поэтому "Выручка"
-- (sort=1, есть во всех месяцах) идёт первой.
WITH f AS (
    SELECT month, metric, sort, amount
    FROM cost_summary_long
    WHERE 1 = 1
        [[ AND {{company}} ]]
        [[ AND {{group}} ]]
        [[ AND {{period}} ]]
),
base AS (
    SELECT metric, sort, toYYYYMM(month) AS col_sort, any(concat(multiIf(toMonth(month)=1,'Янв', toMonth(month)=2,'Фев', toMonth(month)=3,'Мар', toMonth(month)=4,'Апр', toMonth(month)=5,'Май', toMonth(month)=6,'Июн', toMonth(month)=7,'Июл', toMonth(month)=8,'Авг', toMonth(month)=9,'Сен', toMonth(month)=10,'Окт', toMonth(month)=11,'Ноя', 'Дек'), '-', substring(toString(toYear(month)), 3, 2))) AS col_label, sum(amount) AS v
    FROM f GROUP BY metric, sort, month
    UNION ALL
    SELECT metric, sort, 999999 AS col_sort, 'Итого' AS col_label, sum(amount) AS v
    FROM f GROUP BY metric, sort
)
SELECT metric AS "Показатель", col_label AS "Месяц", round(v) AS "Сумма, ₽"
FROM base
ORDER BY sort, col_sort
