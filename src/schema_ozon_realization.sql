-- Сырые данные Ozon Seller API /v2/finance/realization — помесячный отчёт
-- "Продажи и возвраты" (Finance → Documents → Sales reports). Пришёл на
-- замену /v3/finance/transaction/list, который Ozon отключил в 2026 году
-- (см. ozon_api_core.py — тот метод и таблица ozon_api_transactions
-- остаются как исторический архив, новых данных туда больше не будет).
--
-- Гранулярность иная, чем у ozon_api_transactions: здесь одна строка —
-- одна позиция товара в отчёте (продажа ИЛИ возврат, см. kind), без
-- operation_id/operation_type и без разбивки на логистику/услуги —
-- только структура комиссии (delivery_commission для продаж,
-- return_commission для возвратов). Ближе по смыслу к ozon_reports
-- (.xlsx "Начисления"), но НЕ идентична ей — сверка возможна только
-- по агрегатам, как и для ozon_api_transactions (см. compare_ozon_sources.py,
-- этот источник туда пока не добавлен).
--
-- Метод отдаёт данные максимум за 1 календарный месяц за запрос —
-- report_month фиксирует, за какой месяц пришла строка (из запроса,
-- не из данных строки — в ответе Ozon нет отдельной даты позиции).

CREATE TABLE IF NOT EXISTS ozon_realization
(
    cabinet                       String,
    report_month                  Date,          -- первое число месяца запроса (year/month в запросе)
    report_number                 String,        -- header.number
    doc_date                      Date,          -- header.doc_date
    start_date                    Date,          -- header.start_date
    stop_date                     Date,          -- header.stop_date
    receiver_name                 String,        -- header.receiver_name (юрлицо продавца — сверка с legal_entity)
    receiver_inn                  String,
    row_number                    Int32,         -- rowNumber
    kind                          Enum8('delivery' = 1, 'return' = 2),  -- какая из commission-структур заполнена
    item_name                     String,
    offer_id                      String,
    barcode                       String,
    sku                           Int64,
    seller_price_per_instance     Float64,
    commission_ratio              Float64,
    price_per_instance            Float64,
    quantity                      Int32,
    amount                        Float64,
    compensation                  Float64,
    commission                    Float64,
    bonus                         Float64,
    standard_fee                  Float64,
    total                         Float64,
    stars                         Float64,
    bank_coinvestment             Float64,
    pick_up_point_coinvestment    Float64,
    loaded_at                     DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
PARTITION BY report_month
-- row_number одна на строку исходного отчёта, но не уникальна на выходе:
-- строка может одновременно нести и продажу, и возврат (delivery_commission
-- И return_commission оба заполнены — 203 из 2405 строк у CloudSix за
-- январь 2026) и разворачивается в две строки таблицы с общим row_number —
-- kind обязателен в ключе, иначе ReplacingMergeTree схлопнет одну из них.
ORDER BY (cabinet, report_month, row_number, kind);
