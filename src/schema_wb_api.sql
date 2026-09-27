-- Сырые данные финансового API WB (отчёт о реализации = "отчёт
-- комиссионера") — тот же отчёт, что продавец скачивает вручную как
-- "Еженедельный детализированный отчёт" (.xlsx → wb_reports) и как сводный
-- отчёт (.xlsx → wb_report_summary), но полученный напрямую по API.
--
-- ПОЛНАЯ ПЕРЕДЕЛКА 2026-09-27. До этого таблица wb_api_realization была
-- построена под метод Statistics API `GET /api/v5/supplier/reportDetailByPeriod`.
-- WB его ОТКЛЮЧИЛ — метод отдаёт HTTP 404 "This method is deprecated"
-- (по открытым данным отключение с 2026-07-15). Проверено живым запросом
-- 2026-09-27 ключом кабинета CloudSix.
--
-- Историческая справка, чтобы не искать заново: в docs/vision.md за
-- 2026-09-13 причина пустой таблицы записана как "бан WB по API на 16
-- дней", а зонд 2026-09-20 показал HTTP 429 у 8 ключей из 9. И то и другое
-- объясняло симптом не той причиной: метода больше нет. Ключи при этом
-- живы — все 9 WB-токенов действительны до 2027-03-16 (проверено локальной
-- расшифровкой JWT, без обращений к API).
--
-- Взамен у WB три метода на ОТДЕЛЬНОМ хосте https://finance-api.wildberries.ru:
--   POST /api/finance/v1/sales-reports/list              — перечень отчётов за период
--   POST /api/finance/v1/sales-reports/detailed          — детализация за период
--   POST /api/finance/v1/sales-reports/detailed/{reportId} — детализация одного отчёта
-- Нужен токен категории "Финансы". Загрузчик (wb_api_core.py) идёт путём
-- list → detailed/{reportId}: так строки сразу привязаны к конкретному
-- отчёту, как в .xlsx, и не нужно угадывать семантику диапазона дат.
--
-- ЛИМИТ: 1 запрос в минуту (X-Ratelimit-Limit: 1). Это не опечатка и не
-- временная мера — планируйте загрузку исходя из этого. На практике
-- (проверено 2026-09-27) недельный отчёт CloudSix — 9574 строки, и при
-- PAGE_LIMIT=10000 он выкачивается ОДНИМ запросом, то есть неделя = 1 запрос
-- на list + по 1 на каждый из двух отчётов ≈ 3 минуты.
--
-- ДАННЫЕ СОШЛИСЬ С РУЧНОЙ ВЫГРУЗКОЙ (проверено 2026-09-27 на отчёте
-- 813819623, CloudSix, неделя 2026-08-10..16 — он есть и в API, и в
-- wb_reports из .xlsx):
--   * строк: 9574 из API против 9574 в wb_reports;
--   * суммы: payable_to_seller/for_pay 2 165 674.87, wb_realized_amount/
--     retail_amount 3 144 004.74, retail_price_with_discount 3 814 608.43,
--     qty/quantity 13 230, логистика 111 646.82, штрафы 75.53, хранение
--     2 761.00, приёмка 40.00, удержания 723 213.80 — все девять совпали
--     до копейки;
--   * разбивка по 14 типам операций (sellerOperName ↔ payment_reason):
--     совпали и количество строк, и деньги, и штуки в КАЖДОМ типе, а не
--     только в итоге. Названия типов совпадают посимвольно;
--   * 9574 уникальных rrdId на 9574 строки, даты строго внутри недели.
-- То есть новое API — полноценная замена ручной выгрузке, а не источник
-- «примерно похожих» цифр.
--
-- Сводки (метод list) сошлись с wb_report_summary тем же порядком: JOIN по
-- report_id = report_number, все 8 сопоставленных показателей по обоим
-- отчётам недели дали ровно 0.00 (проверено прямым SQL на проде 2026-09-27,
-- не только скриптом).
--
-- ИМЕНА КОЛОНОК. API отдаёт camelCase (rrdId, forPay, paidStorage), в
-- проекте везде snake_case. Колонки названы механическим преобразованием
-- camelCase → snake_case (rrdId → rrd_id, forPay → for_pay,
-- salePriceWholesaleDiscountPrc → sale_price_wholesale_discount_prc), то же
-- преобразование зашито в wb_api_core.camel_to_snake(). Обратное
-- соответствие восстанавливается однозначно, а SQL остаётся в стиле
-- остальной базы. Имена НЕ подгонялись под старые v5-имена и НЕ под
-- колонки wb_reports — WB не использует общий словарь имён между .xlsx и
-- API, поэтому сверка идёт по агрегатам (compare_wb_sources.py), а не
-- построчно.
--
-- ДЕНЬГИ. В новом API денежные значения приходят СТРОКАМИ ("3058674.41"),
-- а не числами — WB сменил тип осознанно. Мы их парсим в Float64, как в
-- wb_reports и во всех метриках: на Float64 настроены существующие сверки
-- (tolerance 0.01-1 ₽), и смешивать Decimal с Float64 в одних сравнениях
-- хуже, чем потерять теоретическую точность на суммах такого масштаба.
-- Если когда-нибудь понадобится копеечная точность в юридическом смысле —
-- менять тип надо здесь и одновременно в wb_reports, иначе сверки поедут.
--
-- ТИПЫ выведены не по одной строке, а по выборке 1005 строк реального
-- отчёта 820964642 (CloudSix, неделя 2026-08-17..23). Поля, которые в
-- выборке всегда пустые, всё равно типизированы по смыслу имени, а не как
-- String — если WB начнёт их заполнять, данные не потеряются.
--
-- НАБОР ПОЛЕЙ У СТРОК РАЗНЫЙ. Это не догадка: в выборке 365 строк по 90
-- полей и 640 по 89, объединение — 91 поле. Необязательные —
-- `bonusTypeName` и `rebillLogisticOrg`. Поэтому ни загрузчик, ни проверка
-- на неизвестные поля НЕ имеют права смотреть только на первую строку
-- ответа: обходить надо каждую. Всё, что
-- API вернёт сверх перечисленного, уходит в extra_fields (Map) и
-- параллельно логируется в wb_api_unmapped_fields_log — тот же приём, что
-- у .xlsx-загрузчика (wb_unmapped_columns_log), и именно он в своё время
-- обнаружил потерянную колонку "Удержание Агентского НДС" у NoxLab.

DROP TABLE IF EXISTS wb_api_realization;

CREATE TABLE IF NOT EXISTS wb_api_realization
(
    cabinet                              String,
    rrd_id                               Int64,    -- уникальный id строки отчёта у WB, ключ дедупликации

    -- шапка отчёта (дублируется в каждой строке, как её отдаёт API)
    report_id                            UInt64,   -- UInt64, а НЕ Int64: ровно как report_number в wb_report_summary/wb_reports, иначе ClickHouse отказывается джойнить ключи ("no supertype for UInt64, Int64") — поймано на живом JOIN 2026-09-27
    report_type                          Nullable(Int32),   -- 1 — основной, 2 — по выкупам
    date_from                            Nullable(Date),
    date_to                              Nullable(Date),
    create_date                          Nullable(Date),
    currency                             Nullable(String),

    -- товар
    subject_name                         Nullable(String),
    nm_id                                Nullable(Int64),
    brand_name                           Nullable(String),
    vendor_code                          Nullable(String),  -- артикул продавца (в .xlsx — "Артикул поставщика")
    title                                Nullable(String),  -- название товара, НОВОЕ поле нового API
    tech_size                            Nullable(String),
    sku                                  Nullable(String),  -- баркод; String, не число (ведущие нули значимы)

    -- операция
    doc_type_name                        Nullable(String),
    seller_oper_name                     Nullable(String),  -- тип операции: Продажа/Возврат/Логистика/...
    quantity                             Nullable(Int32),
    order_dt                             Nullable(DateTime),
    sale_dt                              Nullable(DateTime),
    rr_date                              Nullable(Date),    -- дата строки отчёта о реализации
    shk_id                               Nullable(Int64),
    order_id                             Nullable(Int64),
    order_uid                            Nullable(String),
    srid                                 Nullable(String),

    -- деньги (в API — строки, здесь Float64, см. шапку)
    retail_price                         Nullable(Float64),
    retail_amount                        Nullable(Float64),
    retail_price_with_disc               Nullable(Float64),
    for_pay                              Nullable(Float64),  -- к перечислению продавцу
    ppvz_sales_commission                Nullable(Float64),
    ppvz_reward                          Nullable(Float64),
    acquiring_fee                        Nullable(Float64),
    vw                                   Nullable(Float64),
    vw_nds                               Nullable(Float64),
    delivery_service                     Nullable(Float64),  -- стоимость логистики
    penalty                              Nullable(Float64),
    additional_payment                   Nullable(Float64),
    rebill_logistic_cost                 Nullable(Float64),
    rebill_logistic_org                  Nullable(String),   -- есть НЕ в каждой строке, см. шапку про необязательные поля
    paid_storage                         Nullable(Float64),
    deduction                            Nullable(Float64),
    paid_acceptance                      Nullable(Float64),
    installment_cofinancing_amount       Nullable(Float64),
    cashback_amount                      Nullable(Float64),
    cashback_discount                    Nullable(Float64),
    cashback_commission_change           Nullable(Float64),

    -- проценты и коэффициенты
    sale_percent                         Nullable(Float64),
    commission_percent                   Nullable(Float64),
    dlv_prc                              Nullable(Float64),
    spp                                  Nullable(Float64),
    kvw_base                             Nullable(Float64),
    kvw                                  Nullable(Float64),
    sup_rating_up                        Nullable(Float64),
    is_kgvp_v2                           Nullable(Float64),
    acquiring_percent                    Nullable(Float64),
    product_discount_for_report          Nullable(Float64),
    seller_promo                         Nullable(Float64),
    wibes_discount_percent               Nullable(Float64),
    warehouse_logistics_coeff            Nullable(Float64),
    seller_promo_id                      Nullable(Int64),
    seller_promo_discount                Nullable(Float64),
    loyalty_id                           Nullable(Int64),
    loyalty_discount                     Nullable(Float64),
    uuid_promocode                       Nullable(String),
    sale_price_promocode_discount_prc    Nullable(Float64),
    article_substitution                 Nullable(String),
    sale_price_affiliated_discount_prc   Nullable(Float64),
    sale_price_wholesale_discount_prc    Nullable(Float64),

    -- логистика, склад, ПВЗ
    delivery_amount                      Nullable(Int32),
    return_amount                        Nullable(Int32),
    delivery_method                      Nullable(String),
    office_name                          Nullable(String),
    gi_id                                Nullable(Int64),
    gi_box_type_name                     Nullable(String),
    fix_tariff_date_from                 Nullable(DateTime),
    fix_tariff_date_to                   Nullable(DateTime),
    ppvz_office_name                     Nullable(String),
    ppvz_office_id                       Nullable(Int64),
    ppvz_supplier_name                   Nullable(String),
    ppvz_supplier_inn                    Nullable(String),
    trbx_id                              Nullable(String),
    sticker_id                           Nullable(String),
    country                              Nullable(String),
    declaration_number                   Nullable(String),
    bonus_type_name                      Nullable(String),
    payment_processing                   Nullable(String),
    acquiring_bank                       Nullable(String),
    payment_schedule                     Nullable(Float64),

    -- флаги
    srv_dbs                              Nullable(UInt8),
    is_b2b                               Nullable(UInt8),
    paid_with_social_certificate         Nullable(UInt8),
    b2b_customer_tin                     Nullable(String),

    extra_fields                         Map(String, String),  -- всё, чего нет в колонках выше
    loaded_at                            DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
PARTITION BY toYYYYMM(coalesce(rr_date, toDate('1970-01-01')))
ORDER BY (cabinet, rrd_id);

-- Перечень отчётов за период — метод list. Это ровно тот же набор
-- показателей, что в сводном .xlsx (wb_report_summary), но по API:
-- одна строка = один отчёт (reportId), суммы по отчёту целиком.
--
-- Отдельная таблица, а не дописывание в wb_report_summary, намеренно:
-- wb_report_summary — сырьё ручной выгрузки со своими именами колонок
-- ("К перечислению за товар" → payable_for_goods), на нём стоит
-- reconcile_wb.py и reconciliation_rules_wb.yaml. Смешав два источника в
-- одной таблице, мы потеряли бы возможность сверить их друг с другом —
-- а это первое, что стоит сделать, когда данные API зальются
-- (ср. compare_wb_sources.py для детальных строк).
--
-- report_id здесь = report_number в wb_report_summary/wb_reports (тот же
-- идентификатор отчёта у WB, в .xlsx он парсится из имени файла) —
-- проверено на данных 2026-09-27: list за неделю 2026-08-10..16 вернул
-- reportId 813819623/813819624, ровно те отчёты, что уже были загружены из
-- .xlsx, и все 8 сопоставленных показателей совпали до копейки по каждому
-- (см. compare_wb_summaries.py). Там же подтверждено: reportType 1 =
-- "Основной", 2 = "По выкупам" (в .xlsx report_type — строка, здесь число).
CREATE TABLE IF NOT EXISTS wb_api_report_summary
(
    cabinet                              String,
    report_id                            UInt64,   -- UInt64, а НЕ Int64: ровно как report_number в wb_report_summary/wb_reports, иначе ClickHouse отказывается джойнить ключи ("no supertype for UInt64, Int64") — поймано на живом JOIN 2026-09-27
    report_type                          Nullable(Int32),   -- 1 — основной, 2 — по выкупам
    seller_finance_name                  Nullable(String),  -- юрлицо/кабинет так, как его называет WB
    date_from                            Nullable(Date),
    date_to                              Nullable(Date),
    create_date                          Nullable(Date),
    currency                             Nullable(String),

    retail_amount_sum                    Nullable(Float64),
    for_pay_sum                          Nullable(Float64),
    avg_sale_percent                      Nullable(Float64),
    delivery_service_sum                 Nullable(Float64),
    paid_storage_sum                     Nullable(Float64),
    paid_acceptance_sum                  Nullable(Float64),
    deduction_sum                        Nullable(Float64),
    penalty_sum                          Nullable(Float64),
    additional_payment_sum               Nullable(Float64),
    cashback_amount_sum                  Nullable(Float64),
    cashback_discount_sum                Nullable(Float64),
    cashback_commission_change_sum       Nullable(Float64),
    payment_schedule                     Nullable(Float64),
    bank_payment_sum                     Nullable(Float64),  -- фактическая выплата на счёт

    extra_fields                         Map(String, String),
    loaded_at                            DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
PARTITION BY toYYYYMM(coalesce(date_from, toDate('1970-01-01')))
ORDER BY (cabinet, report_id);

-- Результаты сверки сводок: wb_api_report_summary (API) против
-- wb_report_summary (ручной .xlsx), см. compare_wb_summaries.py.
--
-- Отдельная таблица, а не api_reconciliation_results: там гранулярность
-- МЕСЯЦ (period_month Date), потому что детальные строки .xlsx и API
-- сопоставимы только агрегатами. Здесь гранулярность ОТЧЁТ — общий ключ
-- report_id есть с обеих сторон, и запихивать его в колонку типа Date было
-- бы порчей схемы. Форма повторяет wb_reconciliation_results
-- (schema_wb_summary.sql), чтобы дашборд строился тем же способом.
CREATE TABLE IF NOT EXISTS wb_api_summary_reconciliation
(
    cabinet         String,
    report_id       UInt64,            -- см. заметку про UInt64 у wb_api_report_summary
    metric          String,             -- имя пары из METRICS в compare_wb_summaries.py
    xlsx_value      Nullable(Float64),  -- из wb_report_summary (ручная выгрузка)
    api_value       Nullable(Float64),  -- из wb_api_report_summary (метод list)
    diff            Nullable(Float64),  -- abs(xlsx_value - api_value)
    diff_pct        Nullable(Float64),
    tolerance       Float64,
    is_ok           UInt8,              -- 1 = diff < tolerance
    run_at          DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(run_at)
ORDER BY (cabinet, report_id, metric);

-- Лог полей, которых не оказалось в колонках выше. Пустой лог = схема
-- покрывает ответ API целиком; непустой = WB что-то добавил, и это "что-то"
-- лежит в extra_fields, а не потеряно. Проверять после каждой загрузки:
--   SELECT endpoint, raw_field, count() FROM wb_api_unmapped_fields_log
--   GROUP BY endpoint, raw_field ORDER BY count() DESC;
CREATE TABLE IF NOT EXISTS wb_api_unmapped_fields_log
(
    seen_at     DateTime DEFAULT now(),
    cabinet     String,
    endpoint    String,   -- 'list' | 'detailed'
    report_id   UInt64,
    raw_field   String
)
ENGINE = MergeTree
ORDER BY (seen_at);
