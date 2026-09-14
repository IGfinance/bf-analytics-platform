-- Metabase: "Модель - WB метрики по кабинету, артикулу и месяцу" —
-- тонкая обёртка над VIEW wb_metrics_by_sku_month (см.
-- ../schema_wb_metrics_views_sku.sql), русские подписи колонок.
--
-- Аналог wb_metrics_model.sql (id 49), но с разрезом по SKU. Формулы
-- НЕ дублируются здесь — правьте в schema_wb_metrics_views_sku.sql.
--
-- Источник для дашборда "WB Полный отчёт по артикулу" — таблица-обёртка
-- поверх этой модели с фильтрами {{cabinet}}/{{sku}}, см.
-- wb_full_report_by_sku.sql.

SELECT
    cabinet                          AS "Кабинет",
    month                             AS "Месяц",
    sku                               AS "Артикул продавца",
    product_name                      AS "Название товара",
    sales_qty                        AS "Кол-во продаж",
    sales_amount                     AS "Продажи",
    spp_amount                       AS "СПП",
    wb_commission                    AS "Комиссия ВБ",
    payable_for_goods                AS "К перечислению за товар",
    logistics_direct                 AS "Логистика прямая",
    logistics_reverse                AS "Логистика обратная",
    fines                            AS "Штрафы",
    commission_correction            AS "Доплаты",
    storage_cost                     AS "Хранение",
    acceptance_cost                  AS "Платная приемка",
    deductions                       AS "Удержание",
    wibes_discount                   AS "Скидка Wibes",
    promotion_cost                   AS "Продвижение WB",
    payable_total                    AS "К перечислению итого"
FROM wb_metrics_by_sku_month
ORDER BY cabinet, sku, month
