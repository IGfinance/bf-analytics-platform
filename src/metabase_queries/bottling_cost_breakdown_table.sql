-- Metabase: "Визуал - Bottling - Подробная себестоимость по категориям"
-- (дашборд "Дашборд - Bottling - Подробная себестоимость", id 18; на дашборде
-- "Себестоимость" id 17 этой карточки нет).
-- Раскрытие итога 90.02.1. Строки: Выручка (чистая, без НДС — как в основной
-- таблице), ИТОГО (себестоимость), затем слои Материалы / ОПР / Прочие прямые
-- (и "Без разбивки", если есть); под каждым из трёх верхних слоёв — строка
-- "% от Выручки" (сумма слоя / Выручка того же месяца), затем строки внутри
-- слоя: для "Материалов" — КАТЕГОРИИ (папки номенклатуры 1С второго уровня:
-- этикетки, QR-коды, преформы… — bottling.material_folder; до конкретных
-- позиций не углубляемся), для "ОПР" и "Прочих прямых" — статьи затрат; без
-- префикса слоя, с отступом из неразрывных пробелов.
-- Источник — VIEW bottling.cost_breakdown_long (cost_of_sales + выручка), ОДИН
-- проход по ней (ARRAY JOIN раскладывает каждую строку на нужные строки
-- таблицы). Только закрытые месяцы 1С. Фильтры: Группа / Период.
-- ОБЫЧНАЯ таблица, не сводная: столбцы — месяцы 2026 года (Янв-26 … Дек-26) +
-- "Итого"; так работают цвета строк (table.column_formatting, highlight_row) и
-- выравнивание — у table.pivot этого нет. ПРИ СМЕНЕ ГОДА перегенерировать
-- запрос: список столбцов привязан к 2026. Значения — текст с пробелами
-- (рубли и проценты в одной таблице); пустая ячейка — нет данных за месяц.
WITH (x -> if(x IS NULL, '',
        concat(if(x < 0, '-', ''),
            multiIf(abs(x) >= 1000000,
                        concat(toString(intDiv(toInt64(round(abs(x))), 1000000)), ' ', lpad(toString(intDiv(toInt64(round(abs(x))) % 1000000, 1000)), 3, '0'), ' ', lpad(toString(toInt64(round(abs(x))) % 1000), 3, '0')),
                    abs(x) >= 1000,
                        concat(toString(intDiv(toInt64(round(abs(x))), 1000)), ' ', lpad(toString(toInt64(round(abs(x))) % 1000), 3, '0')),
                    toString(toInt64(round(abs(x)))))))) AS fmt_rub,
     (x -> if(x IS NULL, '',
        concat(replaceOne(if(position(toString(round(x, 1)), '.') = 0, concat(toString(round(x, 1)), '.0'), toString(round(x, 1))), '.', ','), ' %'))) AS fmt_pct
SELECT
    if(is_pct = 1, '% от Выручки', label) AS "Статья",
    if(is_pct = 1, fmt_pct(if(r1 > 0, 100 * m1 / r1, NULL)), fmt_rub(m1)) AS "Янв-26",
    if(is_pct = 1, fmt_pct(if(r2 > 0, 100 * m2 / r2, NULL)), fmt_rub(m2)) AS "Фев-26",
    if(is_pct = 1, fmt_pct(if(r3 > 0, 100 * m3 / r3, NULL)), fmt_rub(m3)) AS "Мар-26",
    if(is_pct = 1, fmt_pct(if(r4 > 0, 100 * m4 / r4, NULL)), fmt_rub(m4)) AS "Апр-26",
    if(is_pct = 1, fmt_pct(if(r5 > 0, 100 * m5 / r5, NULL)), fmt_rub(m5)) AS "Май-26",
    if(is_pct = 1, fmt_pct(if(r6 > 0, 100 * m6 / r6, NULL)), fmt_rub(m6)) AS "Июн-26",
    if(is_pct = 1, fmt_pct(if(r7 > 0, 100 * m7 / r7, NULL)), fmt_rub(m7)) AS "Июл-26",
    if(is_pct = 1, fmt_pct(if(r8 > 0, 100 * m8 / r8, NULL)), fmt_rub(m8)) AS "Авг-26",
    if(is_pct = 1, fmt_pct(if(r9 > 0, 100 * m9 / r9, NULL)), fmt_rub(m9)) AS "Сен-26",
    if(is_pct = 1, fmt_pct(if(r10 > 0, 100 * m10 / r10, NULL)), fmt_rub(m10)) AS "Окт-26",
    if(is_pct = 1, fmt_pct(if(r11 > 0, 100 * m11 / r11, NULL)), fmt_rub(m11)) AS "Ноя-26",
    if(is_pct = 1, fmt_pct(if(r12 > 0, 100 * m12 / r12, NULL)), fmt_rub(m12)) AS "Дек-26",
    if(is_pct = 1, fmt_pct(if(rt > 0, 100 * total / rt, NULL)), fmt_rub(total)) AS "Итого"
FROM
(
    SELECT label, g, ord, m1, m2, m3, m4, m5, m6, m7, m8, m9, m10, m11, m12, total,
           sumIf(m1, g = 0) OVER () AS r1,
           sumIf(m2, g = 0) OVER () AS r2,
           sumIf(m3, g = 0) OVER () AS r3,
           sumIf(m4, g = 0) OVER () AS r4,
           sumIf(m5, g = 0) OVER () AS r5,
           sumIf(m6, g = 0) OVER () AS r6,
           sumIf(m7, g = 0) OVER () AS r7,
           sumIf(m8, g = 0) OVER () AS r8,
           sumIf(m9, g = 0) OVER () AS r9,
           sumIf(m10, g = 0) OVER () AS r10,
           sumIf(m11, g = 0) OVER () AS r11,
           sumIf(m12, g = 0) OVER () AS r12,
           sumIf(total, g = 0) OVER () AS rt
    FROM
    (
        SELECT t.1 AS label, t.2 AS g, t.3 AS ord,
               if(countIf(month = toDate('2026-01-01')) = 0, NULL, sumIf(amount, month = toDate('2026-01-01'))) AS m1,
               if(countIf(month = toDate('2026-02-01')) = 0, NULL, sumIf(amount, month = toDate('2026-02-01'))) AS m2,
               if(countIf(month = toDate('2026-03-01')) = 0, NULL, sumIf(amount, month = toDate('2026-03-01'))) AS m3,
               if(countIf(month = toDate('2026-04-01')) = 0, NULL, sumIf(amount, month = toDate('2026-04-01'))) AS m4,
               if(countIf(month = toDate('2026-05-01')) = 0, NULL, sumIf(amount, month = toDate('2026-05-01'))) AS m5,
               if(countIf(month = toDate('2026-06-01')) = 0, NULL, sumIf(amount, month = toDate('2026-06-01'))) AS m6,
               if(countIf(month = toDate('2026-07-01')) = 0, NULL, sumIf(amount, month = toDate('2026-07-01'))) AS m7,
               if(countIf(month = toDate('2026-08-01')) = 0, NULL, sumIf(amount, month = toDate('2026-08-01'))) AS m8,
               if(countIf(month = toDate('2026-09-01')) = 0, NULL, sumIf(amount, month = toDate('2026-09-01'))) AS m9,
               if(countIf(month = toDate('2026-10-01')) = 0, NULL, sumIf(amount, month = toDate('2026-10-01'))) AS m10,
               if(countIf(month = toDate('2026-11-01')) = 0, NULL, sumIf(amount, month = toDate('2026-11-01'))) AS m11,
               if(countIf(month = toDate('2026-12-01')) = 0, NULL, sumIf(amount, month = toDate('2026-12-01'))) AS m12,
               sum(amount) AS total
        FROM cost_breakdown_long
        ARRAY JOIN arrayConcat(
            if(is_revenue = 1,
               [('Выручка', toUInt8(0), toUInt8(0))],
               [('ИТОГО', toUInt8(1), toUInt8(0)), (layer, toUInt8(multiIf(layer = 'Материалы', 2, layer = 'ОПР', 3, layer = 'Прочие прямые', 4, 5)), toUInt8(0))]),
            arraySlice([(concat(unhex('C2A0C2A0C2A0'),
                               if(layer = 'Материалы', if(material_category != '', material_category, '—'),
                                  if(cost_item != '', cost_item, '—'))),
                         toUInt8(multiIf(layer = 'Материалы', 2, layer = 'ОПР', 3, layer = 'Прочие прямые', 4, 5)), toUInt8(2))],
                       1, if(is_revenue = 0 AND layer != 'Без разбивки', 1, 0))
        ) AS t
        WHERE toYear(month) = 2026
            AND (is_revenue = 1 OR month IN (SELECT month FROM cost_account_20_check WHERE abs(diff) < 1 AND credit_20 > 0))
            [[ AND {{group}} ]]
            [[ AND {{period}} ]]
        GROUP BY label, g, ord
    )
)
ARRAY JOIN [0, 1] AS is_pct
WHERE is_pct = 0 OR (ord = 0 AND g IN (2, 3, 4))
ORDER BY g, ord, is_pct, if(ord = 2, -total, 0), label
