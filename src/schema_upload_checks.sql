-- Журнал проверок при ручной загрузке (ТЗ 04, блок A).
-- Применяется в БД КАЖДОГО проекта (cloudsix, realt): по строке на (файл, проверка).
-- Запись в журнал не должна ломать загрузку (см. upload_checks/core.py: persist).
CREATE TABLE IF NOT EXISTS upload_checks
(
    run_at              DateTime DEFAULT now(),
    user_id             UInt32,
    project             String,
    cabinet             String,
    source              LowCardinality(String),  -- wb_detail | ozon_accruals | ...
    source_file         String,
    check_name          LowCardinality(String),
    severity            LowCardinality(String),  -- info | warn | error
    message             String,
    rows_in_file        UInt32,
    rows_written        UInt32,
    duplicates_skipped  UInt32
)
ENGINE = MergeTree
ORDER BY (run_at, source, cabinet)
TTL toDateTime(run_at) + INTERVAL 2 YEAR;
