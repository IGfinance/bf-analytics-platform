-- Результаты сверки "выгрузка из API" vs "ручная выгрузка из кабинета"
-- (wb_api_realization/ozon_api_transactions против wb_reports/ozon_reports).
-- Общая таблица для обеих площадок — один дашборд в Metabase на обе.

CREATE TABLE IF NOT EXISTS api_reconciliation_results
(
    cabinet        String,
    platform       String,      -- 'wb' | 'ozon'
    period_month   Date,        -- первое число месяца, за который сравниваются суммы
    metric         String,      -- напр. 'payable_to_seller_vs_ppvz_for_pay'
    xlsx_value     Float64,
    api_value      Float64,
    diff           Float64,
    diff_pct       Nullable(Float64),
    tolerance      Float64,
    is_ok          UInt8,
    checked_at     DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(checked_at)
ORDER BY (cabinet, platform, period_month, metric);
