-- Таблица сводного еженедельного отчёта WB ("Отчёт о продажах по реализации")
-- Одна строка на (cabinet, report_number). Загружается через wb_summary_core.py.
-- Колонки соответствуют 21 полю сводного xlsx от WB.

CREATE TABLE IF NOT EXISTS wb_report_summary
(
    cabinet                         String,
    report_number                   UInt64,

    -- Метаданные отчёта
    legal_entity                    Nullable(String),   -- "Юридическое лицо"
    period_start                    Nullable(Date),     -- "Дата начала"
    period_end                      Nullable(Date),     -- "Дата конца"
    formed_at                       Nullable(Date),     -- "Дата формирования"
    report_type                     Nullable(String),   -- "Тип отчета" (Основной / По выкупам)
    currency                        Nullable(String),   -- "Валюта"

    -- Финансовые поля (все в валюте отчёта, обычно RUB)
    sale                            Nullable(Float64),  -- "Продажа"
    loyalty_discount_compensation   Nullable(Float64),  -- "В том числе Компенсация скидки по программе лояльности"
    payable_for_goods               Nullable(Float64),  -- "К перечислению за товар"
    agreed_discount_pct             Nullable(Float64),  -- "Согласованная скидка, %"
    logistics_cost                  Nullable(Float64),  -- "Стоимость логистики"
    storage_cost                    Nullable(Float64),  -- "Стоимость хранения"
    acceptance_cost                 Nullable(Float64),  -- "Стоимость операций на приемке"
    other_deductions                Nullable(Float64),  -- "Прочие удержания/выплаты"
    total_fines                     Nullable(Float64),  -- "Общая сумма штрафов"
    wb_commission_correction        Nullable(Float64),  -- "Корректировка Вознаграждения Вайлдберриз (ВВ)"
    loyalty_program_cost            Nullable(Float64),  -- "Стоимость участия в программе лояльности"
    loyalty_points_deducted         Nullable(Float64),  -- "Сумма баллов, удержанных по программе лояльности"
    one_time_payment_term_change    Nullable(Float64),  -- "Разовое изменение срока перечисления денежных средств"
    total_payable                   Nullable(Float64),  -- "Итого к оплате"

    source_file     String,
    loaded_at       DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
PARTITION BY toYYYYMM(coalesce(period_start, toDate('1970-01-01')))
ORDER BY (cabinet, report_number);


-- Таблица результатов сверки: одна строка на (cabinet, report_number, field_name).
-- Заполняется reconcile_wb.py. Используется для дашборда в Metabase.

CREATE TABLE IF NOT EXISTS wb_reconciliation_results
(
    cabinet         String,
    report_number   UInt64,
    report_type     Nullable(String),   -- Основной / По выкупам (из wb_report_summary)
    period_start    Nullable(Date),
    period_end      Nullable(Date),

    field_name      String,             -- summary_column из reconciliation_rules_wb.yaml
    expected_value  Nullable(Float64),  -- значение из wb_report_summary (сводный отчёт)
    actual_value    Nullable(Float64),  -- агрегат из wb_reports по ch_expression
    diff            Nullable(Float64),  -- abs(expected_value - actual_value)
    tolerance       Float64,            -- допуск из YAML
    is_ok           UInt8,              -- 1 = diff <= tolerance, 0 = расхождение
    status          LowCardinality(String), -- ok / mismatch / missing_raw / missing_summary

    run_at          DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(run_at)
PARTITION BY toYYYYMM(coalesce(period_start, toDate('1970-01-01')))
ORDER BY (cabinet, report_number, field_name);
