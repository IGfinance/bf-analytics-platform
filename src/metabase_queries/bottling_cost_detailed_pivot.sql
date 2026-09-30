-- Дашборд "Bottling - Подробная себестоимость" (id 18). Строки: ИТОГО,
-- затем группа расходов (слой: Материалы/ОПР/Прочие прямые/Без разбивки)
-- и её статьи (для Материалы — по материалу, для ОПР/Прочие прямые — по
-- статье затрат из 1С; глубже эти статьи в cost_of_sales не разложены).
-- Столбцы — месяцы + Итого. Источник — bottling.cost_of_sales, фильтры
-- Группа (номенклатурная, т.е. какой продукт) / Период. Выручка/% от
-- выручки — на дашборде "Bottling - Себестоимость" (id 17), здесь не
-- дублируем (join к cost_summary_long ломал дашборд-фильтр, см. вики).
WITH f AS (
    SELECT month, layer, cost_item, material, amount
    FROM cost_of_sales
    WHERE 1 = 1
        [[ AND {{group}} ]]
        [[ AND {{period}} ]]
),
lines AS (
    SELECT month, layer,
           if(layer = 'Материалы' AND material != '', material,
              if(cost_item != '', cost_item, '—')) AS item,
           amount
    FROM f
),
base AS (
    SELECT 'ИТОГО' AS row_label, 0 AS lsort, 0 AS is_detail, toYYYYMM(month) AS col_sort,
           any(concat(multiIf(toMonth(month)=1,'Янв', toMonth(month)=2,'Фев', toMonth(month)=3,'Мар', toMonth(month)=4,'Апр', toMonth(month)=5,'Май', toMonth(month)=6,'Июн', toMonth(month)=7,'Июл', toMonth(month)=8,'Авг', toMonth(month)=9,'Сен', toMonth(month)=10,'Окт', toMonth(month)=11,'Ноя', 'Дек'), '-', substring(toString(toYear(month)), 3, 2))) AS col_label, sum(amount) AS v
    FROM f GROUP BY month
    UNION ALL
    SELECT 'ИТОГО', 0, 0, 999999, 'Итого', sum(amount) FROM f
    UNION ALL
    SELECT layer, multiIf(layer='Материалы',1, layer='ОПР',2, layer='Прочие прямые',3, 4), 0,
           toYYYYMM(month), any(concat(multiIf(toMonth(month)=1,'Янв', toMonth(month)=2,'Фев', toMonth(month)=3,'Мар', toMonth(month)=4,'Апр', toMonth(month)=5,'Май', toMonth(month)=6,'Июн', toMonth(month)=7,'Июл', toMonth(month)=8,'Авг', toMonth(month)=9,'Сен', toMonth(month)=10,'Окт', toMonth(month)=11,'Ноя', 'Дек'), '-', substring(toString(toYear(month)), 3, 2))), sum(amount)
    FROM f GROUP BY layer, month
    UNION ALL
    SELECT layer, multiIf(layer='Материалы',1, layer='ОПР',2, layer='Прочие прямые',3, 4), 0,
           999999, 'Итого', sum(amount)
    FROM f GROUP BY layer
    UNION ALL
    SELECT concat(layer, ' › ', item), multiIf(layer='Материалы',1, layer='ОПР',2, layer='Прочие прямые',3, 4), 1,
           toYYYYMM(month), any(concat(multiIf(toMonth(month)=1,'Янв', toMonth(month)=2,'Фев', toMonth(month)=3,'Мар', toMonth(month)=4,'Апр', toMonth(month)=5,'Май', toMonth(month)=6,'Июн', toMonth(month)=7,'Июл', toMonth(month)=8,'Авг', toMonth(month)=9,'Сен', toMonth(month)=10,'Окт', toMonth(month)=11,'Ноя', 'Дек'), '-', substring(toString(toYear(month)), 3, 2))), sum(amount)
    FROM lines GROUP BY layer, item, month
    UNION ALL
    SELECT concat(layer, ' › ', item), multiIf(layer='Материалы',1, layer='ОПР',2, layer='Прочие прямые',3, 4), 1,
           999999, 'Итого', sum(amount)
    FROM lines GROUP BY layer, item
),
tot AS (SELECT row_label, sumIf(v, col_sort = 999999) AS t FROM base GROUP BY row_label)
SELECT b.row_label AS "Группа расходов", b.col_label AS "Месяц", round(b.v) AS "Сумма, ₽"
FROM base AS b
INNER JOIN tot ON tot.row_label = b.row_label
ORDER BY b.lsort, b.is_detail, tot.t DESC, b.row_label, b.col_sort
