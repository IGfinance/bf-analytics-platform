-- Сырые данные WB Statistics API (v5/supplier/reportDetailByPeriod) —
-- тот же отчёт о реализации, что продавец скачивает вручную как
-- "Еженедельный детализированный отчёт" (.xlsx, таблица wb_reports),
-- но полученный напрямую по API. Поля API называются иначе, чем колонки
-- .xlsx (WB не использует общий словарь имён между экспортом и API),
-- поэтому это отдельная таблица с полями "как есть" из ответа API,
-- а не расширение wb_reports.
--
-- rrd_id — собственный уникальный id строки отчёта у WB, есть только в
-- API (в .xlsx такого столбца нет) — используем как ключ дедупликации.
--
-- Сверяется с wb_reports по агрегатам (см. compare_wb_sources.py), не по
-- rrd_id — построчного соответствия между .xlsx и API нет.

CREATE TABLE IF NOT EXISTS wb_api_realization
(
    cabinet                          String,
    rrd_id                           Int64,
    realizationreport_id             Int64,
    date_from                        Nullable(Date),
    date_to                          Nullable(Date),
    create_dt                        Nullable(Date),
    currency_name                    Nullable(String),
    suppliercontract_code            Nullable(String),
    gi_id                             Nullable(Int64),
    dlv_prc                           Nullable(Float64),
    fix_tariff_date_from              Nullable(DateTime),
    fix_tariff_date_to                Nullable(DateTime),
    subject_name                      Nullable(String),
    nm_id                              Nullable(Int64),
    brand_name                        Nullable(String),
    sa_name                            Nullable(String),
    ts_name                            Nullable(String),
    barcode                            Nullable(String),
    doc_type_name                      Nullable(String),
    quantity                           Nullable(Int32),
    retail_price                       Nullable(Float64),
    retail_amount                      Nullable(Float64),
    sale_percent                       Nullable(Float64),
    commission_percent                 Nullable(Float64),
    office_name                        Nullable(String),
    supplier_oper_name                 Nullable(String),
    order_dt                           Nullable(DateTime),
    sale_dt                            Nullable(DateTime),
    rr_dt                              Nullable(Date),
    shk_id                             Nullable(Int64),
    retail_price_withdisc_rub          Nullable(Float64),
    delivery_amount                    Nullable(Int32),
    return_amount                      Nullable(Int32),
    delivery_rub                       Nullable(Float64),
    gi_box_type_name                   Nullable(String),
    product_discount_for_report        Nullable(Float64),
    supplier_promo                     Nullable(Float64),
    ppvz_spp_prc                       Nullable(Float64),
    ppvz_kvw_prc_base                  Nullable(Float64),
    ppvz_kvw_prc                       Nullable(Float64),
    sup_rating_prc_up                  Nullable(Float64),
    is_kgvp_v2                         Nullable(Float64),
    ppvz_sales_commission              Nullable(Float64),
    ppvz_for_pay                       Nullable(Float64),
    ppvz_reward                        Nullable(Float64),
    acquiring_fee                      Nullable(Float64),
    acquiring_percent                  Nullable(Float64),
    payment_processing                 Nullable(String),
    acquiring_bank                     Nullable(String),
    ppvz_vw                            Nullable(Float64),
    ppvz_vw_nds                        Nullable(Float64),
    ppvz_office_name                   Nullable(String),
    ppvz_office_id                     Nullable(Int64),
    ppvz_supplier_id                   Nullable(Int64),
    ppvz_supplier_name                 Nullable(String),
    ppvz_inn                           Nullable(String),
    declaration_number                 Nullable(String),
    bonus_type_name                    Nullable(String),
    sticker_id                         Nullable(String),
    site_country                       Nullable(String),
    srv_dbs                            Nullable(UInt8),
    penalty                            Nullable(Float64),
    additional_payment                 Nullable(Float64),
    rebill_logistic_cost               Nullable(Float64),
    storage_fee                        Nullable(Float64),
    deduction                          Nullable(Float64),
    acceptance                         Nullable(Float64),
    assembly_id                        Nullable(Int64),
    srid                               Nullable(String),
    report_type                        Nullable(Int32),
    is_legal_entity                    Nullable(UInt8),
    trbx_id                            Nullable(String),
    installment_cofinancing_amount     Nullable(Float64),
    wibes_wb_discount_percent          Nullable(Float64),
    cashback_amount                    Nullable(Float64),
    cashback_discount                  Nullable(Float64),
    cashback_commission_change         Nullable(Float64),
    order_uid                          Nullable(String),
    payment_schedule                   Nullable(Int32),
    delivery_method                    Nullable(String),
    extra_fields                       Map(String, String),  -- поля, которых нет в перечисленных выше (WB время от времени добавляет новые)
    source_date_from                   Date,   -- период запроса, которым была получена строка
    source_date_to                     Date,
    loaded_at                          DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
PARTITION BY toYYYYMM(coalesce(rr_dt, toDate('1970-01-01')))
ORDER BY (cabinet, rrd_id);
