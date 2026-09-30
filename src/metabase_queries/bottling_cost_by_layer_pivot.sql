-- Metabase: "Визуал - Bottling - Себестоимость по группам расходов"
-- (дашборд "Дашборд - Bottling - Подробная себестоимость"). Кросс-таб:
-- строки — ИТОГО + группа расходов (слой: Материалы / ОПР / Прочие
-- прямые / Без разбивки), пока верхнеуровнево — без раскрытия по статьям
-- и материалам (см. bottling_cost_breakdown_pivot.sql для детализации).
-- Столбцы — месяцы + "Итого". Источник — VIEW bottling.cost_of_sales
-- (распределение итога 90.02.1 по структуре выпуска месяца, не факт).
-- Фильтры: Группа (номенклатурная группа) / Период — компании тут нет,
-- себестоимость считается до уровня клиента.
WITH f AS (
    SELECT month, layer, amount
    FROM cost_of_sales
    WHERE 1 = 1
        [[ AND {{group}} ]]
        [[ AND {{period}} ]]
),
base AS (
    SELECT 'ИТОГО' AS row_label, 0 AS lsort, toYYYYMM(month) AS col_sort,
           any(concat(multiIf(toMonth(month)=1,'Янв', toMonth(month)=2,'Фев', toMonth(month)=3,'Мар', toMonth(month)=4,'Апр', toMonth(month)=5,'Май', toMonth(month)=6,'Июн', toMonth(month)=7,'Июл', toMonth(month)=8,'Авг', toMonth(month)=9,'Сен', toMonth(month)=10,'Окт', toMonth(month)=11,'Ноя', 'Дек'), '-', substring(toString(toYear(month)), 3, 2))) AS col_label, sum(amount) AS v
    FROM f GROUP BY month
    UNION ALL
    SELECT 'ИТОГО', 0, 999999, 'Итого', sum(amount) FROM f
    UNION ALL
    SELECT layer, multiIf(layer='Материалы',1, layer='ОПР',2, layer='Прочие прямые',3, 4),
           toYYYYMM(month), any(concat(multiIf(toMonth(month)=1,'Янв', toMonth(month)=2,'Фев', toMonth(month)=3,'Мар', toMonth(month)=4,'Апр', toMonth(month)=5,'Май', toMonth(month)=6,'Июн', toMonth(month)=7,'Июл', toMonth(month)=8,'Авг', toMonth(month)=9,'Сен', toMonth(month)=10,'Окт', toMonth(month)=11,'Ноя', 'Дек'), '-', substring(toString(toYear(month)), 3, 2))), sum(amount)
    FROM f GROUP BY layer, month
    UNION ALL
    SELECT layer, multiIf(layer='Материалы',1, layer='ОПР',2, layer='Прочие прямые',3, 4),
           999999, 'Итого', sum(amount)
    FROM f GROUP BY layer
),
tot AS (SELECT row_label, sumIf(v, col_sort = 999999) AS t FROM base GROUP BY row_label)
SELECT b.row_label AS "Группа расходов", b.col_label AS "Месяц", round(b.v) AS "Сумма, ₽"
FROM base AS b
INNER JOIN tot ON tot.row_label = b.row_label
ORDER BY b.lsort, tot.t DESC, b.row_label, b.col_sort
