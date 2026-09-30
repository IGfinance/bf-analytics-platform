-- Metabase: "Визуал - Bottling - Маржа, % по месяцам" (дашборд
-- "Дашборд - Bottling - Себестоимость"). Одна строка: маржа / выручка по
-- месяцам + "Итого". Отдельной карточкой, чтобы проценты не смешивались
-- с рублями в одной колонке. Источник и фильтры — как у
-- bottling_cost_summary_pivot.sql. Маржа — после ВСЕЙ себестоимости
-- (ставка группы + пул месяца); июль–август выглядят завышенными
-- (~80%) — возможное недосписание себестоимости в 1С, см. вики.
WITH f AS (
    SELECT month, metric, amount
    FROM cost_summary_long
    WHERE metric IN ('Выручка', 'Маржа')
        [[ AND {{company}} ]]
        [[ AND {{group}} ]]
        [[ AND {{period}} ]]
),
base AS (
    SELECT toYYYYMM(month) AS col_sort, any(concat(multiIf(toMonth(month)=1,'Янв', toMonth(month)=2,'Фев', toMonth(month)=3,'Мар', toMonth(month)=4,'Апр', toMonth(month)=5,'Май', toMonth(month)=6,'Июн', toMonth(month)=7,'Июл', toMonth(month)=8,'Авг', toMonth(month)=9,'Сен', toMonth(month)=10,'Окт', toMonth(month)=11,'Ноя', 'Дек'), '-', substring(toString(toYear(month)), 3, 2))) AS col_label,
           sumIf(amount, metric = 'Маржа') AS m, sumIf(amount, metric = 'Выручка') AS r
    FROM f GROUP BY month
    UNION ALL
    SELECT 999999, 'Итого', sumIf(amount, metric = 'Маржа'), sumIf(amount, metric = 'Выручка') FROM f
)
SELECT 'Маржа, %' AS "Показатель", col_label AS "Месяц", round(100 * m / r, 1) AS "Маржа, %"
FROM base WHERE r != 0
ORDER BY col_sort
