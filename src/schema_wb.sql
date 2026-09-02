-- Таблица сырых данных WB "Еженедельный детализированный отчет"
-- Генерируется на основе column_mapping_wb.yaml — при изменении маппинга
-- сверяйтесь с этим файлом и накатывайте ALTER TABLE вручную.

CREATE TABLE IF NOT EXISTS wb_reports
(
    cabinet        String,
    report_number  UInt64,
    row_num                                  Int32,
    supply_number                            Nullable(String),
    subject_category                         Nullable(String),
    nomenclature_code                        Nullable(String),
    brand                                    Nullable(String),
    supplier_article                         Nullable(String),
    product_name                             Nullable(String),
    size                                     Nullable(String),
    barcode                                  Nullable(String),
    document_type                            Nullable(String),
    payment_reason                           Nullable(String),
    order_date                               Nullable(Date),
    sale_date                                Nullable(Date),
    qty                                      Nullable(Int32),
    retail_price                             Nullable(Float64),
    wb_realized_amount                       Nullable(Float64),
    agreed_product_discount_pct              Nullable(Float64),
    promo_code_pct                           Nullable(Float64),
    total_agreed_discount_pct                Nullable(Float64),
    retail_price_with_discount               Nullable(Float64),
    kvv_reduction_rating_pct                 Nullable(Float64),
    kvv_change_promo_pct                     Nullable(Float64),
    platform_discount_pct                    Nullable(Float64),
    kvv_pct                                  Nullable(Float64),
    kvv_base_excl_vat_pct                    Nullable(Float64),
    total_kvv_excl_vat_pct                   Nullable(Float64),
    sales_commission_before_agent_fee_excl_vat Nullable(Float64),
    pvz_handling_compensation                Nullable(Float64),
    payment_services_compensation            Nullable(Float64),
    payment_services_compensation_pct        Nullable(Float64),
    payment_compensation_type                Nullable(String),
    wb_commission_excl_vat                   Nullable(Float64),
    vat_on_wb_commission                     Nullable(Float64),
    payable_to_seller                        Nullable(Float64),
    delivery_qty                             Nullable(Int32),
    return_qty                               Nullable(Int32),
    delivery_service_cost                    Nullable(Float64),
    fixation_start_date                      Nullable(Date),
    fixation_end_date                        Nullable(Date),
    paid_delivery_flag                       Nullable(String),
    total_fines                              Nullable(Float64),
    wb_commission_correction                 Nullable(Float64),
    logistics_fines_corrections_type         Nullable(String),
    marketplace_sticker                      Nullable(String),
    acquiring_bank_name                      Nullable(String),
    office_number                            Nullable(String),
    delivery_office_name                     Nullable(String),
    partner_inn                              Nullable(String),
    partner                                  Nullable(String),
    warehouse                                Nullable(String),
    country                                  Nullable(String),
    box_type                                 Nullable(String),
    customs_declaration_number               Nullable(String),
    assembly_order_number                    Nullable(String),
    marking_code                             Nullable(String),
    sku_barcode                              Nullable(String),
    srid                                     Nullable(String),
    transport_warehouse_compensation         Nullable(Float64),
    transport_organizer                      Nullable(String),
    storage_cost                             Nullable(Float64),
    deductions                               Nullable(Float64),
    acceptance_operations                    Nullable(Float64),
    chrt_id                                  Nullable(String),
    warehouse_fixed_coefficient              Nullable(Float64),
    legal_entity_sale_flag                   Nullable(String),
    inventory_item                           Nullable(String),
    box_number                               Nullable(String),
    cofinancing_discount                     Nullable(Float64),
    wibes_discount_pct                       Nullable(Float64),
    loyalty_discount_compensation            Nullable(Float64),
    loyalty_program_cost                     Nullable(Float64),
    loyalty_points_deducted                  Nullable(Float64),
    basket_id                                Nullable(String),
    one_time_payment_term_change             Nullable(String),
    sale_method_product_type                 Nullable(String),
    seller_promo_id                          Nullable(String),
    seller_promo_discount_pct                Nullable(Float64),
    loyalty_discount_id                      Nullable(String),
    loyalty_discount_pct                     Nullable(Float64),
    promo_code_id                            Nullable(String),
    promo_code_discount_pct                  Nullable(Float64),
    substitute_article_id                    Nullable(String),
    substitute_article_discount_pct          Nullable(Float64),
    wholesale_business_discount_pct          Nullable(Float64),
    buyer_inn                                Nullable(String),
    social_certificate_payment               Nullable(Float64),
    extra_columns  Map(String, String),  -- значения колонок, которых нет в маппинге
    source_file    String,
    loaded_at      DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
-- часть строк (логистика/хранение/штрафы) не привязана к дате продажи —
-- для них используем 1970-01-01, чтобы не терять данные
PARTITION BY toYYYYMM(coalesce(order_date, sale_date, toDate('1970-01-01')))
ORDER BY (cabinet, report_number, row_num);

-- Лог заголовков, которых не оказалось в column_mapping_wb.yaml
CREATE TABLE IF NOT EXISTS wb_unmapped_columns_log
(
    seen_at          DateTime DEFAULT now(),
    source_file      String,
    raw_column_name  String
)
ENGINE = MergeTree
ORDER BY (seen_at);
