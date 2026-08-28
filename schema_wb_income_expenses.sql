-- Агрегированные итоги отчёта WB «Доходы и расходы» за период.
-- Одна строка на (cabinet, period_start). Загружается через wb_income_expenses_core.py.
-- Повторная загрузка того же периода перезаписывает запись (ReplacingMergeTree).
-- Применять вручную на сервере: clickhouse-client < schema_wb_income_expenses.sql

CREATE TABLE IF NOT EXISTS wb_income_expenses
(
    cabinet        String,
    period_start   Date,
    period_end     Date,

    -- Количественные показатели
    n_sales        Int64,    -- «Продажи, шт»
    n_returns      Int64,    -- «Возвраты, шт»

    -- Финансовые показатели (знак как в файле: расходы отрицательные)
    sales_rub      Float64,  -- «Продажи, ₽»
    returns_rub    Float64,  -- «Возвраты, ₽»       (отрицательное)
    logistics_rub  Float64,  -- «Логистика, ₽»      (отрицательное)
    fines_rub      Float64,  -- «Штрафы, ₽»         (отрицательное)
    commission_rub Float64,  -- «Комиссия WB, ₽»    (отрицательное)
    acquiring_rub  Float64,  -- «Эквайринг, ₽»      (отрицательное)
    losses_rub     Float64,  -- «Потери, подмены...»
    bonuses_rub    Float64,  -- «Доплаты, ₽»
    loyalty_rub    Float64,  -- «Программа лояльности, ₽»
    total_rub      Float64,  -- «Итог, ₽»            = фактическое К перечислению

    source_file    String,
    loaded_at      DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
PARTITION BY toYYYYMM(period_start)
ORDER BY (cabinet, period_start);
