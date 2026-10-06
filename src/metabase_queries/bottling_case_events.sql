-- Metabase: "Визуал - Bottling - Списания июня, хронология операций"
-- Все события цепочки по двум случаям (вода 18,9 л и соки «ДБ»): оплата → поступление → списание.
SELECT
    case_name                      AS "Случай",
    toString(event_date)           AS "Дата",
    stage                          AS "Этап",
    document                       AS "Документ",
    counterparty                   AS "Контрагент",
    nomenclature                   AS "Позиция",
    if(quantity = 0, NULL, quantity) AS "Количество",
    if(price = 0, NULL, price)     AS "Цена без НДС, ₽",
    round(amount, 2)               AS "Сумма, ₽",
    note                           AS "Комментарий"
FROM bottling.writeoff_case
ORDER BY case_name, event_date, stage_no, document
