-- Отчёт Ozon "Взаиморасчёты" (/v1/finance/cash-flow-statement/list) — периоды
-- выплат (~неделя), с итемизированной разбивкой по категориям (реклама,
-- хранение, подписки, логистика и т.д.), которых нет ни в ozon_realization
-- (/v2/finance/realization, только выручка/комиссия по товару), ни в
-- ozon_accruals (/v1/finance/accrual/postings, только то, что привязано
-- к конкретному отправлению — а реклама/подписки/склад у Ozon НЕ привязаны
-- к отправлению вообще). Запрашивается напрямую по периоду (date.from/to),
-- без обходного поиска через даты создания отправлений — в отличие от
-- accrual/postings, здесь не нужен lookback за пределы месяца.
--
-- Поле loan (займы/досрочные выплаты) сознательно исключено из "суммы к
-- перечислению" при сверке — это отдельный финансовый механизм (аванс под
-- будущие поступления), не начисление за товар/услуги. Без него сумма
-- (delivery.total + return.total + rfbs.total + services.total + others.total)
-- сходится с ozon_reports/ozon_api_transactions до 0.03% (проверено на
-- CloudSix, январь 2026).

CREATE TABLE IF NOT EXISTS ozon_cashflow_periods
(
    cabinet                String,
    period_begin            Date,
    period_end               Date,
    begin_balance_amount      Float64,
    invoice_transfer           Float64,  -- сумма к перечислению за период (по документу Ozon)
    loan                        Float64,  -- НЕ включать в сверку суммы к перечислению — см. комментарий выше
    payments_total              Float64,  -- сумма фактических выплат за период
    delivery_amount              Float64,  -- выручка минус базовая комиссия (без логистики)
    delivery_services_total       Float64,  -- логистика по доставке (отдельно от delivery_amount)
    delivery_total                 Float64,  -- delivery_amount + delivery_services_total
    return_amount                   Float64,
    return_services_total            Float64,
    return_total                      Float64,
    rfbs_total                         Float64,
    services_total                      Float64,  -- реклама/подписки/хранение и т.п. — см. ozon_cashflow_items
    others_total                        Float64,  -- компенсации и разное — см. ozon_cashflow_items
    currency                            String,
    loaded_at                           DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
PARTITION BY toYYYYMM(period_begin)
ORDER BY (cabinet, period_begin);

-- Итемизированная разбивка — по одной строке на статью (Ozon отдаёт название
-- операции и сумму, без количества/цены за единицу — это агрегат за период,
-- не по отдельным товарам).
CREATE TABLE IF NOT EXISTS ozon_cashflow_items
(
    cabinet       String,
    period_begin   Date,
    bucket          Enum8('delivery_services' = 1, 'return_services' = 2, 'services' = 3, 'others' = 4),
    item_name        String,
    price             Float64,
    line_number        Int32,  -- позиция в массиве items (в ответе Ozon нет своего id строки)
    loaded_at            DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
PARTITION BY toYYYYMM(period_begin)
ORDER BY (cabinet, period_begin, bucket, line_number);
