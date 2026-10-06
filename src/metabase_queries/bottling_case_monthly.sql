-- Metabase: "Визуал - Bottling - Соки ДБ, от оплаты до списания по месяцам"
-- Три позиции соков, списанные в июне 2026: оплаты поставщику, поступления на склад, списание — по месяцам.
-- Оплаты — платежи поставщику «ИМПЕРИЯ-ТРЕЙД ООО» (банк) и взаимозачёты с ним (он же покупатель): они покрывают
-- поставки и этих трёх позиций, и других «ДБ» и прочего, так что с поступлением ТОЛЬКО этих трёх позиций напрямую не
-- сравниваются, а показывают, как и когда рассчитывались с поставщиком.
SELECT
    formatDateTime(month, '%Y-%m')                       AS "Месяц",
    round(paid)                                          AS "Оплачено деньгами, ₽",
    round(offset_amt)                                    AS "Закрыто взаимозачётом, ₽",
    round(sum(paid + offset_amt) OVER (ORDER BY month))  AS "Оплачено и зачтено нарастающим, ₽",
    round(received_qty)                                  AS "Поступило, шт",
    round(received_amt)                                  AS "Поступило без НДС, ₽",
    round(sum(received_amt) OVER (ORDER BY month))       AS "Поступило нарастающим, ₽",
    round(written_off)                                   AS "Списано, ₽",
    round(sum(received_amt) OVER (ORDER BY month) - sum(written_off) OVER (ORDER BY month)) AS "Поступления минус списание нарастающим, ₽"
FROM
(
    SELECT toStartOfMonth(event_date) AS month,
           sumIf(amount, stage = 'Оплата поставщику') AS paid,
           sumIf(amount, stage = 'Взаимозачёт') AS offset_amt,
           sumIf(quantity, stage_no = 2) AS received_qty,
           sumIf(amount, stage_no = 2) AS received_amt,
           sumIf(amount, stage_no = 3) AS written_off
    FROM bottling.writeoff_case WHERE case_name = 'Соки ДБ'
    GROUP BY month
)
ORDER BY month
