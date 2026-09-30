-- Дашборд "Bottling - Подробная себестоимость" (id 18). Строки: Чистая
-- выручка, Себестоимость, затем по каждой группе расходов (слой:
-- Материалы/ОПР/Прочие прямые/Без разбивки) — сумма + "% от Чистой
-- выручки", и внутри группы — её статьи, тоже с "%". Столбцы — месяцы +
-- Итого. cost_of_sales даёт себестоимость, cost_summary_long — выручку/
-- возвраты; group+period фильтруют первую, group2+period2 — вторую (два
-- тега вместо одного — Field Filter жёстко подставляет alias своей
-- таблицы). Длинный заголовок-комментарий здесь ломает подстановку
-- параметров в этой версии Metabase (JDBC "больше параметров, чем можем
-- обработать") — держать его коротким.
-- rev считается один раз и джойнится к costs один раз (не по разу на
-- слой/статью) — иначе 8 проходов по cost_summary_long и 504/обрыв
-- соединения.
WITH
    (x -> concat(if(x < 0, '-', ''),
        multiIf(abs(x) >= 1000000,
                    concat(toString(intDiv(abs(x), 1000000)), ' ', lpad(toString(intDiv(abs(x) % 1000000, 1000)), 3, '0'), ' ', lpad(toString(abs(x) % 1000), 3, '0')),
                abs(x) >= 1000,
                    concat(toString(intDiv(abs(x), 1000)), ' ', lpad(toString(abs(x) % 1000), 3, '0')),
                toString(abs(x))))) AS fmt,
    ((n, d) -> if(d != 0, concat(replaceOne(if(position(toString(round(100 * n / d, 1)), '.') = 0, concat(toString(round(100 * n / d, 1)), '.0'), toString(round(100 * n / d, 1))), '.', ','), ' %'), '—')) AS pct,
    (m -> concat(multiIf(toMonth(m)=1,'Янв', toMonth(m)=2,'Фев', toMonth(m)=3,'Мар', toMonth(m)=4,'Апр', toMonth(m)=5,'Май', toMonth(m)=6,'Июн', toMonth(m)=7,'Июл', toMonth(m)=8,'Авг', toMonth(m)=9,'Сен', toMonth(m)=10,'Окт', toMonth(m)=11,'Ноя', 'Дек'), '-', substring(toString(toYear(m)), 3, 2))) AS monthlab,
    (layer -> multiIf(layer = 'Материалы', 1, layer = 'ОПР', 2, layer = 'Прочие прямые', 3, 4)) AS lrank,
    f AS (
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
    item_rank AS (
        SELECT layer, item, row_number() OVER (PARTITION BY layer ORDER BY sum(amount) DESC) AS rnk
        FROM lines GROUP BY layer, item
    ),
    costs AS (
        SELECT 'Себестоимость' AS row_label, toInt16(-1) AS sort1, toUInt32(0) AS sort2, toUInt8(0) AS kind, toUInt32(toYYYYMM(month)) AS col_sort, sum(amount) AS amt
        FROM f GROUP BY month
        UNION ALL
        SELECT 'Себестоимость', toInt16(-1), toUInt32(0), toUInt8(0), toUInt32(999999), sum(amount) FROM f

        UNION ALL
        SELECT layer, toInt16(lrank(layer)), toUInt32(0), toUInt8(1), toUInt32(toYYYYMM(month)), sum(amount)
        FROM f GROUP BY layer, month
        UNION ALL
        SELECT layer, toInt16(lrank(layer)), toUInt32(0), toUInt8(1), toUInt32(999999), sum(amount)
        FROM f GROUP BY layer

        UNION ALL
        SELECT concat(l.layer, ' › ', l.item), toInt16(lrank(l.layer)), toUInt32(ir.rnk), toUInt8(2), toUInt32(toYYYYMM(l.month)), sum(l.amount)
        FROM lines AS l INNER JOIN item_rank AS ir ON ir.layer = l.layer AND ir.item = l.item
        GROUP BY l.layer, l.item, ir.rnk, l.month
        UNION ALL
        SELECT concat(l.layer, ' › ', l.item), toInt16(lrank(l.layer)), toUInt32(ir.rnk), toUInt8(2), toUInt32(999999), sum(l.amount)
        FROM lines AS l INNER JOIN item_rank AS ir ON ir.layer = l.layer AND ir.item = l.item
        GROUP BY l.layer, l.item, ir.rnk
    ),
    rev_raw AS (
        SELECT month, sumIf(amount, metric = 'Выручка') - sumIf(amount, metric = 'Возвраты') AS net
        FROM cost_summary_long
        WHERE metric IN ('Выручка', 'Возвраты')
            [[ AND {{group2}} ]]
            [[ AND {{period2}} ]]
        GROUP BY month
    ),
    rev AS (
        SELECT toUInt32(toYYYYMM(month)) AS col_sort, net FROM rev_raw
        UNION ALL
        SELECT toUInt32(999999), sum(net) FROM rev_raw
    ),
    cols AS (
        SELECT DISTINCT toUInt32(toYYYYMM(month)) AS col_sort, monthlab(month) AS col_label FROM f
        UNION ALL
        SELECT toUInt32(999999), 'Итого'
    )
SELECT b.row_label AS "Группа расходов", c.col_label AS "Месяц", b.value_str AS "Значение"
FROM
(
    SELECT 'Чистая выручка' AS row_label, toInt16(-2) AS sort1, toUInt32(0) AS sort2, toUInt8(0) AS line_type, col_sort AS col_sort, fmt(toInt64(round(net))) AS value_str
    FROM rev

    UNION ALL
    SELECT row_label, sort1, sort2, toUInt8(0) AS line_type, col_sort, fmt(toInt64(round(amt))) AS value_str
    FROM costs WHERE kind = 0

    UNION ALL
    SELECT t.2 AS row_label, x.sort1 AS sort1, x.sort2 AS sort2, t.1 AS line_type, x.col_sort AS col_sort, t.3 AS value_str
    FROM costs AS x INNER JOIN rev ON rev.col_sort = x.col_sort
    ARRAY JOIN [(toUInt8(0), x.row_label, fmt(toInt64(round(x.amt)))), (toUInt8(1), concat(x.row_label, ' — % от Чистой выручки'), pct(x.amt, rev.net))] AS t
    WHERE x.kind IN (1, 2)
) AS b
INNER JOIN cols AS c ON c.col_sort = b.col_sort
ORDER BY b.sort1, b.sort2, b.line_type, b.col_sort
