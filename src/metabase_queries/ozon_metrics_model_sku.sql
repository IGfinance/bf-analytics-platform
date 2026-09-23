-- Metabase: "Модель - Ozon метрики по кабинету, артикулу и месяцу" (id 191 в
-- проде на 2026-09-23 — id меняется, если модель пересоздать, сверяйтесь по
-- имени). Ozon-аналог "Модель - WB метрики по кабинету, артикулу и месяцу"
-- (wb_metrics_model_sku.sql, id 90).
--
-- Тонкая обёртка над ClickHouse VIEW ozon_metrics_by_sku_month
-- (src/schema_ozon_metrics_views_sku.sql) — только русские подписи колонок,
-- формулы живут в VIEW. Правьте формулы там.
--
-- Строка "без артикула" — не мусор, а account-level расходы Ozon (реклама,
-- FBO, компенсации, прочие начисления), которые площадка начисляет на
-- кабинет целиком и которые намеренно НЕ размазаны по товарам.

SELECT
    cabinet                                AS "Кабинет",
    month                                   AS "Месяц",
    sku                                     AS "Артикул продавца",
    product_name                            AS "Название товара",
    sales_qty                               AS "Кол-во продаж",
    sales_with_spp                          AS "Выручка + СПП",
    sales_amount                            AS "Выручка",
    spp_amount                              AS "СПП",
    commission                              AS "Комиссия",
    returns_corrections                     AS "Корректировки, брак, потери и возвраты",
    payable_for_goods                       AS "К перечислению за товар",
    logistics_cost                          AS "Логистика",
    last_mile_cost                          AS "Последняя миля",
    fines                                   AS "Штрафы",
    surcharges                              AS "Доплаты",
    storage_cost                            AS "Хранение на складе",
    promotion_cost                          AS "Продвижение",
    other_accruals                          AS "Прочие начисления",
    payable_total                           AS "Выручка к перечислению",
    cogs                                    AS "Себестоимость",
    gross_profit                            AS "Валовая прибыль",
    cogs_qty_covered                        AS "Ед. с себестоимостью",
    cogs_qty_uncovered                      AS "Ед. без себестоимости"
FROM ozon_metrics_by_sku_month
ORDER BY cabinet, sku, month
