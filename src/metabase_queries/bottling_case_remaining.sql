-- Metabase: "Визуал - Bottling - Соки ДБ, что ещё лежит на 10.01"
-- Остаток номенклатуры «ДБ …» на счёте 10.01 по учёту 1С на последний загруженный конец месяца: то, что не списано
-- и (по данным 1С) не продаётся — кандидаты на такое же списание, как в июне.
SELECT
    if(nomenclature = '', 'ИТОГО', nomenclature)  AS "Позиция",
    round(sum(quantity))                          AS "Остаток, шт",
    round(sum(amount))                            AS "Остаток, ₽",
    round(sum(amount) / nullIf(sum(quantity), 0), 1) AS "На шт, ₽",
    toString(max(month_end))                      AS "На дату"
FROM bottling.balances
WHERE account = '10.01' AND nomenclature LIKE 'ДБ %'
  AND month_end = (SELECT max(month_end) FROM bottling.balances)
GROUP BY nomenclature WITH ROLLUP
HAVING sum(amount) != 0
ORDER BY nomenclature = '', sum(amount) DESC
