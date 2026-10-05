-- Metabase: "Визуал - Bottling - Закупки материалов" (генерируется scripts/gen_bottling_chain_cards.py)
-- Строки — материал; под ним Количество / Цена за ед. (без НДС, средняя взвешенная) / Сумма без НДС;
-- столбцы — месяцы 2026 + Итого. Закупки — Document_ПоступлениеТоваровУслуг, счёт учёта 10.01.
-- Строки с подозрительной ценой (price_ok = 0, ошибка единицы в 1С) остаются в количестве и сумме.
WITH
    (x -> if(x IS NULL, '',
        concat(if(x < 0, '-', ''),
            multiIf(abs(x) >= 1000000,
                        concat(toString(intDiv(toInt64(round(abs(x))), 1000000)), ' ', lpad(toString(intDiv(toInt64(round(abs(x))) % 1000000, 1000)), 3, '0'), ' ', lpad(toString(toInt64(round(abs(x))) % 1000), 3, '0')),
                    abs(x) >= 1000,
                        concat(toString(intDiv(toInt64(round(abs(x))), 1000)), ' ', lpad(toString(toInt64(round(abs(x))) % 1000), 3, '0')),
                    toString(toInt64(round(abs(x)))))))) AS fmt_int,
    (x -> if(x IS NULL, '', replaceOne(toString(round(x, 3)), '.', ','))) AS fmt_dec,
    (x -> if(x IS NULL, '', concat(replaceOne(if(position(toString(round(x, 1)), '.') = 0, concat(toString(round(x, 1)), '.0'), toString(round(x, 1))), '.', ','), ' %'))) AS fmt_pct,
    agg AS (
        SELECT nomenclature AS mat, any(unit) AS unit, month, sum(quantity) AS q, sum(amount_net) AS a
        FROM bottling.purchases WHERE month >= '2026-01-01'
        GROUP BY mat, month WITH ROLLUP
        HAVING mat != ''
    ),
    ranked AS (
        SELECT *, max(if(month = toDate('1970-01-01'), a, NULL)) OVER (PARTITION BY mat) AS tot
        FROM agg
    )
SELECT
    if(k = 1, mat, '') AS "Материал",
    if(k = 1, unit, '') AS "Ед.",
    ['Количество', 'Цена за ед., ₽', 'Сумма, ₽'][k] AS "Показатель",
    multiIf(k = 1, fmt_int(max(if(month = toDate('2026-01-01'), q, NULL))), k = 2, fmt_dec(max(if(month = toDate('2026-01-01'), a / nullIf(q, 0), NULL))), fmt_int(max(if(month = toDate('2026-01-01'), a, NULL)))) AS "Янв-26",
    multiIf(k = 1, fmt_int(max(if(month = toDate('2026-02-01'), q, NULL))), k = 2, fmt_dec(max(if(month = toDate('2026-02-01'), a / nullIf(q, 0), NULL))), fmt_int(max(if(month = toDate('2026-02-01'), a, NULL)))) AS "Фев-26",
    multiIf(k = 1, fmt_int(max(if(month = toDate('2026-03-01'), q, NULL))), k = 2, fmt_dec(max(if(month = toDate('2026-03-01'), a / nullIf(q, 0), NULL))), fmt_int(max(if(month = toDate('2026-03-01'), a, NULL)))) AS "Мар-26",
    multiIf(k = 1, fmt_int(max(if(month = toDate('2026-04-01'), q, NULL))), k = 2, fmt_dec(max(if(month = toDate('2026-04-01'), a / nullIf(q, 0), NULL))), fmt_int(max(if(month = toDate('2026-04-01'), a, NULL)))) AS "Апр-26",
    multiIf(k = 1, fmt_int(max(if(month = toDate('2026-05-01'), q, NULL))), k = 2, fmt_dec(max(if(month = toDate('2026-05-01'), a / nullIf(q, 0), NULL))), fmt_int(max(if(month = toDate('2026-05-01'), a, NULL)))) AS "Май-26",
    multiIf(k = 1, fmt_int(max(if(month = toDate('2026-06-01'), q, NULL))), k = 2, fmt_dec(max(if(month = toDate('2026-06-01'), a / nullIf(q, 0), NULL))), fmt_int(max(if(month = toDate('2026-06-01'), a, NULL)))) AS "Июн-26",
    multiIf(k = 1, fmt_int(max(if(month = toDate('2026-07-01'), q, NULL))), k = 2, fmt_dec(max(if(month = toDate('2026-07-01'), a / nullIf(q, 0), NULL))), fmt_int(max(if(month = toDate('2026-07-01'), a, NULL)))) AS "Июл-26",
    multiIf(k = 1, fmt_int(max(if(month = toDate('2026-08-01'), q, NULL))), k = 2, fmt_dec(max(if(month = toDate('2026-08-01'), a / nullIf(q, 0), NULL))), fmt_int(max(if(month = toDate('2026-08-01'), a, NULL)))) AS "Авг-26",
    multiIf(k = 1, fmt_int(max(if(month = toDate('2026-09-01'), q, NULL))), k = 2, fmt_dec(max(if(month = toDate('2026-09-01'), a / nullIf(q, 0), NULL))), fmt_int(max(if(month = toDate('2026-09-01'), a, NULL)))) AS "Сен-26",
    multiIf(k = 1, fmt_int(max(if(month = toDate('2026-10-01'), q, NULL))), k = 2, fmt_dec(max(if(month = toDate('2026-10-01'), a / nullIf(q, 0), NULL))), fmt_int(max(if(month = toDate('2026-10-01'), a, NULL)))) AS "Окт-26",
    multiIf(k = 1, fmt_int(max(if(month = toDate('2026-11-01'), q, NULL))), k = 2, fmt_dec(max(if(month = toDate('2026-11-01'), a / nullIf(q, 0), NULL))), fmt_int(max(if(month = toDate('2026-11-01'), a, NULL)))) AS "Ноя-26",
    multiIf(k = 1, fmt_int(max(if(month = toDate('2026-12-01'), q, NULL))), k = 2, fmt_dec(max(if(month = toDate('2026-12-01'), a / nullIf(q, 0), NULL))), fmt_int(max(if(month = toDate('2026-12-01'), a, NULL)))) AS "Дек-26",
    multiIf(k = 1, fmt_int(max(if(month = toDate('1970-01-01'), q, NULL))), k = 2, fmt_dec(max(if(month = toDate('1970-01-01'), a / nullIf(q, 0), NULL))), fmt_int(max(if(month = toDate('1970-01-01'), a, NULL)))) AS "Итого"
FROM ranked
ARRAY JOIN [1, 2, 3] AS k
GROUP BY mat, unit, tot, k
ORDER BY tot DESC, mat, k
