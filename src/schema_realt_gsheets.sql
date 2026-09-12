-- Ручные выгрузки Google-Таблиц Реальта (зарплаты, расходы по статьям).
-- TODO(Илья): точная структура колонок — по факту согласованного формата
-- таблиц, уточнить перед реализацией парсера (realt_gsheets_core.py).
-- Обе таблицы держим отдельно, т.к. это разные по смыслу сущности (ФОТ vs
-- расходы по статьям), а не варианты одного отчёта.

CREATE TABLE IF NOT EXISTS realt_payroll
(
    project_id     UInt32,
    period         Nullable(Date),   -- TODO(Илья): месяц периода начисления
    -- TODO(Илья): сотрудник/должность/сумма и т.д.
    extra_columns  Map(String, String),
    row_num        UInt32,           -- позиция строки в исходном файле, для дедупа при перезаливке
    source_file    String,
    loaded_at      DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
PARTITION BY toYYYYMM(coalesce(period, toDate('1970-01-01')))
ORDER BY (project_id, source_file, row_num);

CREATE TABLE IF NOT EXISTS realt_expenses
(
    project_id     UInt32,
    expense_date   Nullable(Date),
    -- TODO(Илья): статья расхода/сумма/контрагент и т.д.
    extra_columns  Map(String, String),
    row_num        UInt32,           -- позиция строки в исходном файле, для дедупа при перезаливке
    source_file    String,
    loaded_at      DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
PARTITION BY toYYYYMM(coalesce(expense_date, toDate('1970-01-01')))
ORDER BY (project_id, source_file, row_num);
