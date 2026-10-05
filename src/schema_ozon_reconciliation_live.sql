-- «Живая» сверка Ozon: новый API (cash-flow) vs .xlsx. Заменяет снимок api_reconciliation_results для Ozon:
-- не заполняется скриптами, а всегда считается из текущих данных (загрузили xlsx / отработал cron — цифры обновились сами).
-- Колонки те же, что у api_reconciliation_results, поэтому карточка Metabase меняет только источник.
--
-- Логика повторяет compare_ozon_cashflow.py и compare_ozon_cashflow_metrics.py:
--   1) total_amount_vs_cashflow_reconciled — сумма ozon_reports.total_amount за месяц vs ozon_cashflow_reconciled_month.reconciled_total,
--      допуск 0.01 ₽; месяц, которого нет в одном из источников, считается нулём (честный пробел, не пропуск);
--   2) cashflow_<метрика> — 8 метрик модели: ozon_metrics_by_cabinet_month vs ..._cashflow_api, допуск 1 ₽,
--      только месяцы, есть в обоих источниках.
-- Кабинеты без данных API (нет ключа) в сверку не входят — иначе у них был бы ложный «❌».

CREATE OR REPLACE VIEW ozon_reconciliation_live AS
WITH
api_cabinets AS (
    SELECT DISTINCT cabinet FROM ozon_cashflow_periods FINAL
),
xlsx_total AS (
    SELECT cabinet, toStartOfMonth(accrual_date) AS month, sum(total_amount) AS v
    FROM ozon_reports FINAL
    WHERE accrual_date IS NOT NULL AND cabinet IN (SELECT cabinet FROM api_cabinets)
    GROUP BY cabinet, month
),
api_total AS (
    SELECT cabinet, toStartOfMonth(month) AS month, sum(reconciled_total) AS v
    FROM ozon_cashflow_reconciled_month
    GROUP BY cabinet, month
),
totals AS (
    SELECT
        coalesce(nullIf(x.cabinet, ''), a.cabinet) AS cabinet,
        if(x.cabinet = '', a.month, x.month) AS period_month,
        'total_amount_vs_cashflow_reconciled' AS metric,
        toFloat64(if(x.cabinet = '', 0, x.v)) AS xlsx_value,
        toFloat64(if(a.cabinet = '', 0, a.v)) AS api_value,
        0.01 AS tolerance
    FROM xlsx_total x
    FULL OUTER JOIN api_total a ON x.cabinet = a.cabinet AND x.month = a.month
),
x_m AS (SELECT cabinet, toStartOfMonth(month) AS month, payable_for_goods, logistics_cost, last_mile_cost, fines, surcharges, storage_cost, promotion_cost, other_accruals
        FROM ozon_metrics_by_cabinet_month),
a_m AS (SELECT cabinet, toStartOfMonth(month) AS month, payable_for_goods, logistics_cost, last_mile_cost, fines, surcharges, storage_cost, promotion_cost, other_accruals
        FROM ozon_metrics_by_cabinet_month_cashflow_api),
metrics AS (
    SELECT
        x.cabinet AS cabinet,
        x.month AS period_month,
        concat('cashflow_', m.1) AS metric,
        toFloat64(ifNull(m.2, 0)) AS xlsx_value,
        toFloat64(ifNull(m.3, 0)) AS api_value,
        1.0 AS tolerance
    FROM x_m x
    INNER JOIN a_m a ON x.cabinet = a.cabinet AND x.month = a.month
    ARRAY JOIN [
        ('payable_for_goods', x.payable_for_goods, a.payable_for_goods),
        ('logistics_cost',    x.logistics_cost,    a.logistics_cost),
        ('last_mile_cost',    x.last_mile_cost,    a.last_mile_cost),
        ('fines',             x.fines,             a.fines),
        ('surcharges',        x.surcharges,        a.surcharges),
        ('storage_cost',      x.storage_cost,      a.storage_cost),
        ('promotion_cost',    x.promotion_cost,    a.promotion_cost),
        ('other_accruals',    x.other_accruals,    a.other_accruals)
    ] AS m
)
SELECT
    cabinet,
    'ozon' AS platform,
    toDate(period_month) AS period_month,
    metric,
    xlsx_value,
    api_value,
    abs(xlsx_value - api_value) AS diff,
    if(xlsx_value != 0, abs(xlsx_value - api_value) / abs(xlsx_value) * 100, NULL) AS diff_pct,
    tolerance,
    toUInt8(abs(xlsx_value - api_value) < tolerance) AS is_ok,
    now() AS checked_at
FROM (SELECT * FROM totals UNION ALL SELECT * FROM metrics);
