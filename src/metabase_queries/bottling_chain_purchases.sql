-- Metabase: "Визуал - Bottling - Закупки материалов"
-- Что закуплено, у кого, когда, по какой цене (без НДС). Параметр {{month}} — любая дата месяца.
SELECT
    formatDateTime(date, '%Y-%m-%d') AS "Дата",
    supplier                         AS "Поставщик",
    nomenclature                     AS "Материал",
    unit                             AS "Ед.",
    quantity                         AS "Количество",
    round(price_net, 3)              AS "Цена без НДС, ₽",
    round(amount_net, 2)             AS "Сумма без НДС, ₽",
    number                           AS "Документ",
    if(price_ok = 1, '', 'проверить единицу')  AS "Пометка"
FROM bottling.purchases
WHERE month = toStartOfMonth(toDate({{month}}))
ORDER BY date, supplier, nomenclature
