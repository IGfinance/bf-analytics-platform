-- Metabase: "Модель - WB юнит-экономика по SKU и месяцу" (id 57 в проде на
-- 2026-09-03, см. dashboards.finance-black.ru — id меняется, если модель
-- пересоздать заново, сверяйтесь по имени, а не по id). Карточка
-- "Таблица - Юнит-экономика по SKU Wb" (id 59, на дашборде id 2) ссылается
-- на неё через {{#57}}, сама формул не копирует.
--
-- То же самое разложение статей, что в "Модель - WB метрики по кабинету и
-- месяцу" (wb_metrics_model.sql, id 49) — см. там подробные комментарии по
-- каждой статье и сознательные отличия от адаптера ig-startup/adapter-wb.
-- Эта модель — тот же расчёт, но с разрезом по SKU (supplier_article,
-- product_name) вместо агрегации только по кабинету/месяцу.
--
-- БЕЗ Себестоимости — как и в модели 49, матрицы СС по артикулам/неделям
-- в ClickHouse пока нет (отдельная задача: загрузка себестоимости).
-- "Маржа на единицу" ниже — это "К перечислению итого" / "Кол-во продаж",
-- то есть выручка продавца после всех удержаний площадки НА ЕДИНИЦУ
-- товара, а не чистая прибыль (для неё не хватает СС и налогов).

WITH cs_k_types AS (
    SELECT arrayJoin([
        'продажа', 'сторно продаж', 'авансовая оплата за товар без движения',
        'возврат', 'корректный возврат', 'корректная продажа',
        'компенсация брака', 'компенсация потерянного товара',
        'сторно возвратов', 'компенсация ущерба',
        'добровольная компенсация при возврате',
        'компенсация подмененного товара', 'частичная компенсация брака'
    ]) AS v
),
base AS (
    SELECT
        cabinet,
        toDateTime(toStartOfMonth(sale_date)) + INTERVAL 12 HOUR AS month,
        coalesce(nullIf(trim(supplier_article), ''), 'без артикула') AS sku,
        anyHeavy(product_name) AS product_name,

        coalesce(sumIf(qty, lowerUTF8(trim(payment_reason)) = 'продажа'), 0) AS n_sale,
        coalesce(sumIf(qty, lowerUTF8(trim(payment_reason)) = 'возврат'), 0) AS n_ret,

        coalesce(sumIf(payable_to_seller,
            lowerUTF8(trim(payment_reason)) IN (SELECT v FROM cs_k_types) AND lowerUTF8(trim(document_type)) = 'продажа'), 0) AS ah_sale,
        coalesce(sumIf(payable_to_seller,
            lowerUTF8(trim(payment_reason)) IN (SELECT v FROM cs_k_types) AND lowerUTF8(trim(document_type)) = 'возврат'), 0) AS ah_ret,

        coalesce(sumIf(delivery_service_cost,
            payment_reason IN ('Логистика', 'Коррекция логистики') AND logistics_fines_corrections_type LIKE '%К клиенту%'), 0) AS direct_logistics,
        coalesce(sumIf(delivery_service_cost,
            payment_reason IN ('Логистика', 'Коррекция логистики') AND (logistics_fines_corrections_type NOT LIKE '%К клиенту%' OR logistics_fines_corrections_type IS NULL)), 0) AS reverse_logistics,

        coalesce(sum(total_fines), 0) AS sum_fines,
        coalesce(sum(wb_commission_correction), 0) AS sum_correction,
        coalesce(sum(storage_cost), 0) AS sum_storage,
        coalesce(sum(acceptance_operations), 0) AS sum_acceptance,
        coalesce(sumIf(deductions,
            trim(REGEXP_REPLACE(REGEXP_REPLACE(logistics_fines_corrections_type, ',\\s*документ\\s*№\\s*\\d+', ''), '\\s+\\d+$', ''))
                NOT IN ('Оказание услуг «WB Продвижение»', 'Оказание услуг «ВБ.Продвижение»')
            OR logistics_fines_corrections_type IS NULL), 0) AS sum_deductions,
        coalesce(sumIf(deductions,
            trim(REGEXP_REPLACE(REGEXP_REPLACE(logistics_fines_corrections_type, ',\\s*документ\\s*№\\s*\\d+', ''), '\\s+\\d+$', ''))
                IN ('Оказание услуг «WB Продвижение»', 'Оказание услуг «ВБ.Продвижение»')), 0) AS sum_promo,

        coalesce(sumIf(loyalty_discount_compensation, document_type = 'Продажа'), 0)
          - coalesce(sumIf(loyalty_discount_compensation, document_type = 'Возврат'), 0) AS sum_loyalty_comp,
        coalesce(sum(loyalty_program_cost), 0) AS sum_loyalty_cost,
        coalesce(sum(loyalty_points_deducted), 0) AS sum_loyalty_points
    FROM wb_reports
    WHERE sale_date IS NOT NULL
    GROUP BY cabinet, month, sku
)
SELECT
    cabinet                                               AS "Кабинет",
    month                                                  AS "Месяц",
    sku                                                    AS "Артикул продавца",
    product_name                                           AS "Название товара",
    (n_sale - n_ret)                                       AS "Кол-во продаж",
    (ah_sale - ah_ret)                                     AS "К перечислению за товар",
    (
      (ah_sale - ah_ret) + (-direct_logistics) + (-reverse_logistics)
      + (-sum_fines) + (-sum_correction) + (-sum_storage) + (-sum_acceptance) + (-sum_deductions)
      + (sum_loyalty_comp - sum_loyalty_cost - sum_loyalty_points) + (-sum_promo)
    )                                                       AS "К перечислению итого",
    if((n_sale - n_ret) != 0,
      (
        (ah_sale - ah_ret) + (-direct_logistics) + (-reverse_logistics)
        + (-sum_fines) + (-sum_correction) + (-sum_storage) + (-sum_acceptance) + (-sum_deductions)
        + (sum_loyalty_comp - sum_loyalty_cost - sum_loyalty_points) + (-sum_promo)
      ) / (n_sale - n_ret),
      NULL
    )                                                       AS "Маржа на единицу (без себестоимости)"
FROM base
ORDER BY cabinet, month, "К перечислению итого" DESC
