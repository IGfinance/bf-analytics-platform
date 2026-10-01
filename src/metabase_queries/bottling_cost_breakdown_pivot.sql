-- Metabase: "Визуал - Bottling - Себестоимость по статьям" (дашборд
-- "Дашборд - Bottling - Себестоимость", карточка 212). Раскрытие итога
-- 90.02.1 по слоям и статьям затрат; для слоя "Материалы" — по КАТЕГОРИИ
-- материала (папка номенклатуры 1С второго уровня: этикетки, QR-коды,
-- преформы, колпачки… — bottling.material_folder), до конкретных позиций
-- не углубляемся; "ОПР" и "Прочие прямые" — по статьям затрат.
-- Дашборд "Дашборд - Bottling - Подробная себестоимость" (id 18); на
-- дашборде "Себестоимость" (id 17) эта карточка НЕ стоит. Столбцы — месяцы + "Итого". Источник — VIEW bottling.cost_of_sales
-- (распределение по структуре выпуска месяца, не факт; ОПР, списанное со
-- склада, отдельной строки не имеет — 1С статей по нему не хранит, оно
-- разнесено по структуре выпуска). Строки: ИТОГО, затем слой (подытог) и
-- его статьи по убыванию. Фильтры: Группа / Период (компании тут нет —
-- себестоимость считается до уровня клиента).
WITH f AS (
    SELECT month, layer, cost_item, material_category, amount
    FROM cost_of_sales
    WHERE month IN (SELECT month FROM cost_account_20_check WHERE abs(diff) < 1 AND credit_20 > 0)  -- только закрытые месяцы, как в основной таблице
        [[ AND {{group}} ]]
        [[ AND {{period}} ]]
),
lines AS (
    SELECT month, layer,
           if(layer = 'Материалы', if(material_category != '', material_category, '—'),
              if(cost_item != '', cost_item, '—')) AS item,
           amount
    FROM f
    WHERE layer != 'Без разбивки'  -- без детализации: подытог слоя и есть вся сумма
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
SELECT b.row_label AS "Статья", b.col_label AS "Месяц", round(b.v) AS "Сумма, ₽"
FROM base AS b
INNER JOIN tot ON tot.row_label = b.row_label
ORDER BY b.lsort, b.is_detail, tot.t DESC, b.row_label, b.col_sort
