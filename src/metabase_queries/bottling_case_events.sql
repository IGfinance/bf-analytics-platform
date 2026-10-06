-- Metabase: "Визуал - Bottling - Списания июня, хронология операций"
-- Все события цепочки по двум случаям (вода 18,9 л и соки «ДБ»): оплата → поступление → списание.
-- Сумма — по документу как есть. Дальше та же сумма раскладывается по смыслу:
--   Реальные деньги — только банковские платежи поставщику (взаимозачёт — не деньги);
--   Начислено — поступление материала на склад (без НДС) и ввод остатка воды;
--   Списано — списание со склада в июне.
-- Нарастающие итоги — внутри случая по порядку дат. «Остаток по учёту» = начислено − списано нарастающим;
-- оплаты и зачёты в нём не участвуют (они относятся ко всем поставкам поставщика, не к конкретным позициям).
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
    round(cash, 2)                 AS "Реальные деньги, ₽",
    round(sum(cash) OVER w, 2)     AS "Реальные деньги нарастающим, ₽",
    round(accrued, 2)              AS "Начислено, ₽",
    round(written_off, 2)          AS "Списано, ₽",
    round(sum(accrued - written_off) OVER w, 2) AS "Остаток по учёту нарастающим, ₽",
    note                           AS "Комментарий"
FROM
(
    SELECT *,
           if(stage = 'Оплата поставщику', amount, 0)           AS cash,
           if(stage_no IN (0, 2), amount, 0)                    AS accrued,
           if(stage_no = 3, amount, 0)                          AS written_off
    FROM bottling.writeoff_case
)
WINDOW w AS (PARTITION BY case_name ORDER BY event_date, stage_no, document
             ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
ORDER BY case_name, event_date, stage_no, document
