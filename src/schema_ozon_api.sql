-- Сырые данные Ozon Seller API (v3/finance/transaction/list) — операции
-- по уже проведённым (закрытым) финансовым начислениям. НЕ включает
-- открытые/необработанные заказы — метод отдаёт только свершившиеся
-- финансовые операции, поэтому доп. фильтрации по статусу не требуется.
--
-- Отдельная от ozon_reports таблица (это данные из другого источника —
-- API, а не выгруженный из кабинета .xlsx), с другой грануляцией:
-- ozon_reports — одна строка = одна услуга/статья в рамках начисления,
-- ozon_api_transactions — одна строка = одна операция API (с вложенным
-- списком услуг operation.services, здесь развёрнутым в parallel-массивы).
-- Сверяются по агрегатам (см. compare_ozon_sources.py), не построчно —
-- операция может группировать несколько строк .xlsx-выгрузки, а услуги
-- вроде эквайринга приходят отдельной операцией с тем же posting_number.

CREATE TABLE IF NOT EXISTS ozon_api_transactions
(
    cabinet                  String,
    operation_id             Int64,
    operation_type           String,
    operation_type_name      String,
    operation_date            DateTime,  -- хранится "как пришло" от Ozon (наивная строка в МСК), но ClickHouse трактует вставку как UTC — при группировке по дате/месяцу нужен addHours(operation_date, 3), см. compare_ozon_sources.py
    delivery_charge           Float64,
    return_delivery_charge    Float64,
    accruals_for_sale         Float64,
    sale_commission            Float64,
    amount                      Float64,
    type                          String,
    posting_number              Nullable(String),
    posting_delivery_schema     Nullable(String),
    posting_order_date          Nullable(DateTime),
    posting_warehouse_id        Nullable(Int64),
    item_names                   Array(String),
    item_skus                    Array(Int64),
    service_names                Array(String),
    service_prices                Array(Float64),
    source_date_from            Date,   -- период запроса, которым была получена строка (для отладки пагинации)
    source_date_to              Date,
    loaded_at                    DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
PARTITION BY toYYYYMM(operation_date)
ORDER BY (cabinet, operation_id);
