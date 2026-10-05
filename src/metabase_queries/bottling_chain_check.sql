-- Metabase: "Визуал - Bottling - Цепочка сверка с проводками"
-- Дт 20.01 / Кт 10.01 по проводкам регламентных операций = в цепочке + без количества в отчётах.
SELECT
    formatDateTime(month, '%Y-%m')   AS "Месяц",
    round(ledger_materials)          AS "Материалы по проводкам, ₽",
    round(in_chain)                  AS "В цепочке, ₽",
    round(no_qty_writeoffs)          AS "Без количества в отчётах, ₽",
    round(ledger_materials - in_chain - no_qty_writeoffs) AS "Расхождение, ₽",
    round(other_writeoffs)           AS "Прочие списания вне цепочки, ₽"
FROM bottling.chain_check
ORDER BY month
