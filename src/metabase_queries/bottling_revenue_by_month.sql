-- Metabase: "Модель - Bottling - Выручка по месяцам" (база "ClickHouse Bottling", id 4).
--
-- Грейн строки — месяц x контрагент x номенклатура. Формула самой
-- выручки НЕ здесь: она уже посчитана в ClickHouse VIEW
-- bottling.realization_revenue (см. src/schema_bottling_realization.sql) —
-- эта карточка просто группирует и суммирует, как Model 49 у WB
-- (wb_metrics_by_cabinet_month_api).
--
-- Выручка = поле "Сумма" строки товара, БЕЗ НДС (сумма с НДС —
-- отдельная колонка на случай, если понадобится).
--
-- Источник ФИЛЬТРУЕТ posted=1 AND deletion_mark=0 уже внутри VIEW —
-- здесь фильтра нет, он не нужен.

SELECT
    month           AS "Месяц",
    counterparty    AS "Контрагент",
    nomenclature    AS "Номенклатура",
    sum(amount)          AS "Выручка",
    sum(amount_with_vat) AS "Выручка с НДС",
    sum(quantity)        AS "Количество"
FROM realization_revenue
GROUP BY month, counterparty, nomenclature
ORDER BY month, counterparty, nomenclature
