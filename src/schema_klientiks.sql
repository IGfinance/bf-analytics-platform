-- Выгрузка из Клиентикс (учётная система клиник) — источник данных
-- проекта Реальт. TODO(Илья): формат выгрузки (CSV/XLSX, какие колонки)
-- уточнить по реальному файлу — колонки ниже заготовка, поправить перед
-- реализацией парсера (klientiks_core.py).
--
-- Для будущих метрик LTV и юнит-экономики по врачам/услугам нужна
-- построчная детализация (пациент/врач/услуга/дата/сумма), а не только
-- агрегаты по месяцу — закладывать это в реальные колонки.
--
-- COMMENT COLUMN обязателен на бизнес-значимых полях, когда формат
-- зафиксирован — см. architecture-standarts.md, "Семантический слой для
-- AI-бота".
CREATE TABLE IF NOT EXISTS klientiks_operations
(
    project_id      UInt32,
    -- TODO(Илья): реальные колонки выгрузки (пациент/врач/услуга/дата
    -- приёма/сумма и т.д.) — ниже временная заглушка.
    operation_date  Nullable(Date),
    extra_columns   Map(String, String),  -- паттерн из wb_reports/bank_statements
    row_num         UInt32,               -- позиция строки в исходном файле, для дедупа при перезаливке
    source_file     String,
    loaded_at       DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
PARTITION BY toYYYYMM(coalesce(operation_date, toDate('1970-01-01')))
ORDER BY (project_id, source_file, row_num);
