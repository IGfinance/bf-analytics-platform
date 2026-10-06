-- Metabase: "Визуал - Bottling - Списания июня, итог по позициям"
-- Разбор 17,55 млн ₽, ушедших в июне 2026 в «Списания: Продукция и товары» подробной себестоимости.
-- Источник — bottling.writeoff_case (src/ingest_bottling_writeoff_case.py) и остатки bottling.balances.
-- Поступило — сумма БЕЗ НДС; остаток на 31.05 — по учёту 1С (счёт 10.01).
SELECT
    if(nomenclature = '', 'ИТОГО', nomenclature)                                   AS "Позиция",
    arrayStringConcat(arraySort(groupUniqArrayIf(document, stage_no = 3)), ', ')      AS "Документы списания",
    round(sumIf(quantity, stage_no = 3))                                              AS "Списано, шт",
    round(sumIf(amount, stage_no = 3))                                                AS "Списано, ₽",
    if(nomenclature = '', NULL, round(sumIf(amount, stage_no = 3) / nullIf(sumIf(quantity, stage_no = 3), 0), 1)) AS "Списано на шт, ₽",
    round(sumIf(quantity, stage_no = 2))                                              AS "Поступило за всё время, шт",
    round(sumIf(amount, stage_no = 2))                                                AS "Поступило без НДС, ₽",
    toString(minIf(event_date, stage_no IN (0, 2)))                                   AS "Первое поступление или ввод",
    if(countIf(stage_no = 2) = 0, '', toString(maxIf(event_date, stage_no = 2)))       AS "Последнее поступление",
    round(any(b.bal_qty))                                                             AS "Остаток на 31.05, шт",
    round(any(b.bal_amt))                                                             AS "Остаток на 31.05, ₽",
    multiIf(nomenclature = '', '',
            countIf(stage_no = 0) > 0, 'Ручной ввод остатка 31.12.2025, Дт 10.01 / Кт 000, без количества',
            countIf(stage_no = 2) > 0, 'Закуплено у ИМПЕРИЯ-ТРЕЙД ООО, 2023–2025', '')   AS "Откуда"
FROM
(
    SELECT e.*, 0 AS dummy FROM bottling.writeoff_case AS e WHERE nomenclature != ''
) AS e
LEFT JOIN
(
    SELECT nomenclature AS nom, sum(quantity) AS bal_qty, sum(amount) AS bal_amt
    FROM bottling.balances WHERE account = '10.01' AND month_end = '2026-05-31' GROUP BY nomenclature
) AS b ON b.nom = e.nomenclature
WHERE e.nomenclature IN (SELECT nomenclature FROM bottling.writeoff_case WHERE stage_no = 3)
GROUP BY nomenclature WITH ROLLUP
ORDER BY nomenclature = '', sumIf(amount, stage_no = 3) DESC
