-- Таблица сырых данных Ozon "Начисления" — структура полностью отличается
-- от wb_reports (нет report_number: один экспортный файл = один произвольный
-- период по кабинету, без нумерации отчётов), поэтому это отдельная таблица,
-- а не расширение wb_reports платформой.
--
-- Генерируется на основе column_mapping_ozon.yaml — при изменении маппинга
-- сверяйтесь с этим файлом и накатывайте ALTER TABLE вручную.
--
-- row_num — не колонка исходника (в отличие от wb_reports, где есть "№"),
-- а позиция строки в файле, присваивается ingest_ozon.py при чтении.
-- Дедуп-ключ (cabinet, source_file, row_num) защищает от повторной загрузки
-- ТОГО ЖЕ файла, но не от задвоения при перекрывающихся выгрузках с разными
-- именами файлов — как и в wb_reports, это ловит duplicate_operations_across_files
-- в check_ozon.py.

CREATE TABLE IF NOT EXISTS ozon_reports
(
    cabinet                  String,
    row_num                  Int32,
    accrual_id               Nullable(String),
    accrual_date             Nullable(Date),
    service_group            Nullable(String),
    accrual_type             Nullable(String),
    article                  Nullable(String),
    sku                      Nullable(String),
    product_name             Nullable(String),
    qty                      Nullable(Int32),
    seller_price             Nullable(Float64),
    order_accepted_date      Nullable(Date),
    sales_platform           Nullable(String),
    fulfillment_scheme       Nullable(String),
    ozon_commission_pct      Nullable(Float64),
    localization_index_pct   Nullable(Float64),
    avg_delivery_hours       Nullable(Float64),
    total_amount             Nullable(Float64),
    extra_columns            Map(String, String),  -- значения колонок, которых нет в маппинге
    source_file              String,
    loaded_at                DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
PARTITION BY toYYYYMM(coalesce(accrual_date, toDate('1970-01-01')))
ORDER BY (cabinet, source_file, row_num);

-- Лог заголовков, которых не оказалось в column_mapping_ozon.yaml
CREATE TABLE IF NOT EXISTS ozon_unmapped_columns_log
(
    seen_at          DateTime DEFAULT now(),
    source_file      String,
    raw_column_name  String
)
ENGINE = MergeTree
ORDER BY (seen_at);
