-- Metabase: "Визуал - Bottling - Кредиты и займы проценты"
-- (дашборд "Дашборд - Bottling - Кредиты и займы"). Строка = начисление
-- процентов по договору за день. Статус — расчётный (FIFO по оплатам,
-- включая удержанный НДФЛ), см. src/schema_bottling_credits.sql.
-- Источник — VIEW bottling.credit_interest.
-- Фильтры (field filter на колонки VIEW): Статус / Кредитор / Период (day).
SELECT
    day AS "Дата",
    round(amount, 2) AS "Сумма",
    concat(counterparty, ' — ', contract) AS "Кредитор и договор",
    status AS "Статус",
    paid AS "Оплачено",
    remaining AS "Остаток",
    if(rate = 0, NULL, rate) AS "Ставка, %"
FROM credit_interest
WHERE 1 = 1
    [[ AND {{status}} ]]
    [[ AND {{creditor}} ]]
    [[ AND {{period}} ]]
ORDER BY day DESC, counterparty, contract
