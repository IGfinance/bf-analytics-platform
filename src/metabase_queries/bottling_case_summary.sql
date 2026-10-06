-- Metabase: "Визуал - Bottling - Списания июня, итог по позициям"
-- Разбор 17,55 млн ₽, ушедших в июне 2026 в «Списания: Продукция и товары» подробной себестоимости, и всего, что
-- с этими позициями произошло: начислено на склад → ушло раньше → списано в июне → осталось.
-- Источник — bottling.writeoff_case (src/ingest_bottling_writeoff_case.py) и остатки bottling.balances.
-- Начислено — поступление без НДС (соки) или ручной ввод остатка (вода). «Ушло до июня» — расход в производство
-- по отчётам производства (рубли — регламентные операции) и списание требованиями на ОПР.
-- Осталось по движению = начислено − ушло до июня − списано в июне; сверка с остатком 10.01 по учёту на 30.06.
SELECT
    if(nomenclature = '', 'ИТОГО', nomenclature)                                         AS "Позиция",
    round(sumIf(quantity, stage_no = 2))                                                    AS "Поступило, шт",
    round(sumIf(amount, stage_no IN (0, 2)))                                                AS "Начислено, ₽",
    round(sumIf(quantity, stage = 'Расход в производство'))                                 AS "Ушло в производство, шт",
    round(sumIf(amount, stage = 'Расход в производство, стоимость'))                        AS "Ушло в производство, ₽",
    round(sumIf(quantity, stage = 'Списание на ОПР'))                                       AS "Списано на ОПР, шт",
    round(sumIf(amount, stage = 'Списание на ОПР'))                                         AS "Списано на ОПР, ₽",
    round(sumIf(quantity, stage = 'Списание'))                                              AS "Списано в июне, шт",
    round(sumIf(amount, stage = 'Списание'))                                                AS "Списано в июне, ₽",
    round(sumIf(quantity, stage_no = 2) - sumIf(quantity, stage_no = 3))                    AS "Осталось по движению, шт",
    round(sumIf(amount, stage_no IN (0, 2)) - sumIf(amount, stage_no = 3))                  AS "Осталось по движению, ₽",
    round(if(nomenclature = '',
             (SELECT sum(amount) FROM bottling.balances WHERE account = '10.01' AND month_end = '2026-06-30'
                AND nomenclature IN (SELECT nomenclature FROM bottling.writeoff_case WHERE stage = 'Списание')),
             any(b.bal_amt)))                                                                   AS "Остаток 10.01 на 30.06 по учёту, ₽",
    toString(minIf(event_date, stage_no IN (0, 2)))                                         AS "Первое поступление или ввод",
    arrayStringConcat(arraySort(groupUniqArrayIf(document, stage = 'Списание')), ', ')      AS "Документы июньского списания"
FROM
(
    SELECT * FROM bottling.writeoff_case WHERE nomenclature != ''
      AND nomenclature IN (SELECT nomenclature FROM bottling.writeoff_case WHERE stage = 'Списание')
) AS e
LEFT JOIN
(
    SELECT nomenclature AS nom, sum(amount) AS bal_amt
    FROM bottling.balances WHERE account = '10.01' AND month_end = '2026-06-30' GROUP BY nomenclature
) AS b ON b.nom = e.nomenclature
GROUP BY nomenclature WITH ROLLUP
ORDER BY nomenclature = '', sumIf(amount, stage = 'Списание') DESC
