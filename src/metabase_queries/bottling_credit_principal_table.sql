-- Metabase: "Визуал - Bottling - Кредиты и займы тело"
-- (дашборд "Дашборд - Bottling - Кредиты и займы"). Строка = получение по
-- договору за день (транш / перенос долга). Статус "Оплачен" / "Частично
-- оплачен" / "Не оплачен" — расчётный: погашения договора зачитываются на
-- самые ранние получения (FIFO), см. src/schema_bottling_credits.sql.
-- Источник — VIEW bottling.credit_principal.
-- Фильтры (field filter на колонки VIEW): Статус / Кредитор / Период (day).
SELECT
    day AS "Дата",
    round(amount, 2) AS "Сумма",
    concat(counterparty, ' — ', contract) AS "Кредитор и договор",
    status AS "Статус",
    paid AS "Оплачено",
    remaining AS "Остаток",
    term_end AS "Срок возврата",
    if(rate = 0, NULL, rate) AS "Ставка, %",
    kind AS "Вид получения"
FROM credit_principal
WHERE 1 = 1
    [[ AND {{status}} ]]
    [[ AND {{creditor}} ]]
    [[ AND {{period}} ]]
ORDER BY day DESC, counterparty, contract
