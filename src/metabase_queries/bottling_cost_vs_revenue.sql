-- Metabase: "Визуал - Bottling - Выручка, себестоимость, % от выручки"
-- (дашборд "Дашборд - Bottling - Себестоимость", id 17). Кросс-таб:
-- столбцы — месяцы + "Итого", строки — Выручка / Себестоимость /
-- % от Выручки. Источник — VIEW bottling.cost_summary_long (только
-- закрытые месяцы 1С; себестоимость = Дт 90.02.1 как в учёте, с долей
-- пула месяца). Значения — текст с пробелами-разделителями тысяч (в одной
-- колонке рубли и проценты, числовой формат их не совместит).
-- ОДИН проход по VIEW (WITH ROLLUP даёт строку "Итого" с month =
-- 1970-01-01, ARRAY JOIN разворачивает три показателя): первая версия
-- обращалась к VIEW шесть раз и упиралась в 504 (60 с) Metabase. Порядок
-- столбцов задаёт первая строка результата — "Выручка" есть во всех
-- месяцах. Фильтры: Компания / Группа / Период.
WITH (x -> concat(if(x < 0, '-', ''),
        multiIf(abs(x) >= 1000000,
                    concat(toString(intDiv(abs(x), 1000000)), ' ', lpad(toString(intDiv(abs(x) % 1000000, 1000)), 3, '0'), ' ', lpad(toString(abs(x) % 1000), 3, '0')),
                abs(x) >= 1000,
                    concat(toString(intDiv(abs(x), 1000)), ' ', lpad(toString(abs(x) % 1000), 3, '0')),
                toString(abs(x))))) AS fmt
SELECT
    t.2 AS "Показатель",
    if(month = toDate('1970-01-01'), 'Итого', concat(multiIf(toMonth(month)=1,'Янв', toMonth(month)=2,'Фев', toMonth(month)=3,'Мар', toMonth(month)=4,'Апр', toMonth(month)=5,'Май', toMonth(month)=6,'Июн', toMonth(month)=7,'Июл', toMonth(month)=8,'Авг', toMonth(month)=9,'Сен', toMonth(month)=10,'Окт', toMonth(month)=11,'Ноя', 'Дек'), '-', substring(toString(toYear(month)), 3, 2))) AS "Месяц",
    t.3 AS "Значение"
FROM
(
    SELECT month,
           sumIf(amount, metric = 'Выручка') AS r,
           sumIf(amount, metric = 'Себестоимость (итого)') AS c
    FROM cost_summary_long
    WHERE metric IN ('Выручка', 'Себестоимость (итого)')
        [[ AND {{company}} ]]
        [[ AND {{group}} ]]
        [[ AND {{period}} ]]
    GROUP BY month WITH ROLLUP
)
ARRAY JOIN [
    (1, 'Выручка', fmt(toInt64(round(r)))),
    (2, 'Себестоимость', fmt(toInt64(round(c)))),
    (3, '% от Выручки', if(r != 0, concat(replaceOne(toString(round(100 * c / r, 1)), '.', ','), ' %'), '—'))
] AS t
ORDER BY t.1, if(month = toDate('1970-01-01'), 999999, toYYYYMM(month))
