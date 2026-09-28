-- Вьюха-переименователь: данные финансового API (wb_api_realization) под
-- ИМЕНАМИ КОЛОНОК ручной выгрузки (wb_reports).
--
-- Зачем. Формула метрик WB живёт в ОДНОМ месте — wb_metrics_by_sku_month
-- (schema_wb_metrics_views_sku.sql). Чтобы посчитать те же метрики на данных
-- API, формулу пришлось бы скопировать и переписать под другие имена полей —
-- а это ровно тот дрейф двух копий, на котором проект уже обжёгся: архивная
-- Модель 57 осталась на старой формуле лояльности и тихо расходилась с боевой
-- (см. заголовок schema_wb_metrics_views_sku.sql).
--
-- Поэтому разница между «метрики из xlsx» и «метрики из API» сведена к ОДНОЙ
-- строке — имени таблицы в FROM. Всё остальное делает эта вьюха, а сам
-- API-вариант метрик генерируется из канонического файла механически
-- (scripts/gen_wb_metrics_api_view.py), и тест не даёт им разойтись.
--
-- СООТВЕТСТВИЕ ПОЛЕЙ проверено на данных 2026-09-28, на отчёте 813819623
-- (CloudSix, есть и в API, и в xlsx) — совпали и разбивки, и суммы:
--   seller_oper_name  ↔ payment_reason                    (14 типов операций)
--   bonus_type_name   ↔ logistics_fines_corrections_type  (совпали посимвольно)
--   delivery_service  ↔ delivery_service_cost             83 095.07
--   deduction         ↔ deductions                        741 421
--   cashback_commission_change ↔ loyalty_program_cost     27.5
--   cashback_discount ↔ loyalty_discount_compensation     7 286.85
--   cashback_amount   ↔ loyalty_points_deducted           -600 / 275
-- Последние три — самое неочевидное: WB переименовал поля программы
-- лояльности в cashback_*. По названию их связать нельзя, только по данным.
--
-- ДВА ПОЛЯ БЕЗ ПАРЫ, оба безопасны:
--   wb_commission_correction («Доплаты») — в API аналога не нашлось, отдаём
--     ноль. Это не потеря: в wb_reports колонка нулевая во ВСЕХ строках за всю
--     историю (0 ненулевых значений), то есть метрика «Доплаты» и сейчас
--     всегда ноль.
--   transport_warehouse_compensation ↔ rebill_logistic_cost — в API есть
--     (904 470 ₽ за 2026), но формула исключает его осознанно с 2026-09-14:
--     это компенсация, которую WB платит своим перевозчикам за свой счёт,
--     она уже сидит внутри комиссии. Отдаём как есть, формула его не читает.
--
-- FINAL обязателен: wb_api_realization — ReplacingMergeTree, и без FINAL
-- повторная загрузка того же отчёта считалась бы дважды.

CREATE VIEW IF NOT EXISTS wb_api_realization_as_reports AS
SELECT
    cabinet                                  AS cabinet,
    report_id                                AS report_number,
    rrd_id                                   AS row_num,

    -- ДАТА ПРОДАЖИ = sale_dt, переведённый в МОСКОВСКОЕ время.
    -- API отдаёт sale_dt в UTC, а .xlsx датирует строки по Москве (UTC+3).
    -- Отсюда два симптома, которые сначала выглядели как разные баги:
    --   вечерняя продажа  sale_dt 2026-08-12 22:15 UTC = 13-го 01:15 МСК,
    --                     .xlsx ставит 2026-08-13,
    --   начисление за продвижение sale_dt 2025-12-31 19:30 UTC = того же дня
    --                     22:30 МСК, .xlsx ставит 2025-12-31.
    -- Оба случая объясняются одним сдвигом на +3 часа, и ничем другим.
    -- rr_date («дата операции») для продаж почти совпадает (98.7%), но для
    -- начислений за услуги системно на сутки позже: они выставляются
    -- последним днём месяца, а проводятся первым днём следующего — и вся
    -- сумма переезжала в соседний месяц (у INOVO 377 435 ₽ с февраля на март).
    -- coalesce на rr_date — страховка для строк без sale_dt.
    coalesce(toDate(sale_dt + INTERVAL 3 HOUR), rr_date) AS sale_date,
    toDate(order_dt + INTERVAL 3 HOUR)       AS order_date,
    rr_date                                  AS rr_date,
    sale_dt                                  AS sale_dt,
    vendor_code                              AS supplier_article,
    title                                    AS product_name,
    subject_name                             AS subject_category,
    brand_name                               AS brand,
    tech_size                                AS size,
    sku                                      AS barcode,
    nm_id                                    AS nomenclature_code,

    doc_type_name                            AS document_type,
    seller_oper_name                         AS payment_reason,
    bonus_type_name                          AS logistics_fines_corrections_type,
    quantity                                 AS qty,

    retail_price                             AS retail_price,
    retail_amount                            AS wb_realized_amount,
    retail_price_with_disc                   AS retail_price_with_discount,
    for_pay                                  AS payable_to_seller,

    delivery_service                         AS delivery_service_cost,
    penalty                                  AS total_fines,
    paid_storage                             AS storage_cost,
    paid_acceptance                          AS acceptance_operations,
    deduction                                AS deductions,

    cashback_discount                        AS loyalty_discount_compensation,
    cashback_commission_change               AS loyalty_program_cost,
    cashback_amount                          AS loyalty_points_deducted,

    -- нет пары в API; в xlsx колонка нулевая во всех строках за всю историю
    CAST(0 AS Nullable(Float64))             AS wb_commission_correction,
    -- формула его не использует (исключён 2026-09-14), отдаём для полноты
    rebill_logistic_cost                     AS transport_warehouse_compensation,

    delivery_amount                          AS delivery_qty,
    return_amount                            AS return_qty,
    office_name                              AS warehouse,
    ppvz_office_name                         AS delivery_office_name,
    country                                  AS country,
    srid                                     AS srid,
    sticker_id                               AS marketplace_sticker,
    acquiring_bank                           AS acquiring_bank_name,
    spp                                      AS platform_discount_pct,
    commission_percent                       AS kvv_pct,
    sale_percent                             AS total_agreed_discount_pct
FROM wb_api_realization FINAL;

ALTER TABLE wb_api_realization_as_reports COMMENT COLUMN payment_reason 'seller_oper_name из API. Совпадает с payment_reason в wb_reports посимвольно — проверено на 14 типах операций отчёта 813819623.';
ALTER TABLE wb_api_realization_as_reports COMMENT COLUMN logistics_fines_corrections_type 'bonus_type_name из API — то же, что "Виды логистики, штрафов и доплат" в .xlsx. На нём стоит разбивка логистики на прямую/обратную и удержаний на продвижение/прочее, поэтому соответствие проверялось отдельно.';
ALTER TABLE wb_api_realization_as_reports COMMENT COLUMN loyalty_program_cost 'cashback_commission_change из API. Поля программы лояльности WB переименовал в cashback_*, по названию связать нельзя — соответствие установлено по данным.';
ALTER TABLE wb_api_realization_as_reports COMMENT COLUMN wb_commission_correction 'Константный 0: в API аналога нет, а в wb_reports эта колонка нулевая во всех строках за всю историю, так что метрика "Доплаты" и без того всегда ноль.';
