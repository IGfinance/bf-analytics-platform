-- СГЕНЕРИРОВАННЫЙ ФАЙЛ. Не правьте руками.
--
-- Генератор: scripts/gen_detail_adapter_views.py (принципы — в его шапке).
--
-- «Детальный адаптер»: все статьи отчётов WB и Ozon в длинном формате
-- (кабинет, бренд, месяц, блок, группа, статья, сумма). Блок «1 Начисления» аддитивен:
-- его сумма = «К перечислению итого» (payable_total) канонических вьюх, остальные блоки
-- справочные и с ним не складываются. Расходы Ozon уровня кабинета разложены по брендам
-- пропорционально выручке (оценка), всё привязанное к артикулу — точно.
--
-- Порядок накатки: после schema_wb_metrics_views_brand.sql и schema_ozon_metrics_views_brand.sql
-- (читают бренд-вьюхи). Применять под пользователем с правом DDL (default). Вьюхи новые.
--
-- ПРОВЕРКА НА ДАННЫХ (инварианты, гонять после любой правки):
--   * WB: по каждому (кабинет, бренд, месяц) сумма листьев группы = каноническая метрика
--     бренд-вьюхи: 01+02 = payable_for_goods; 03 = logistics_direct + logistics_reverse; 04 = fines;
--     05 = commission_correction; 06 = storage_cost; 07 = acceptance_cost; 08 = deductions;
--     09 = promotion_cost; 10 = wibes_discount; весь блок «1» = payable_total.
--   * Ozon xlsx: блок «1» = payable_total бренд-вьюхи ozon_metrics_by_cabinet_brand_month.
--   * Ozon API: блок «1» = payable_total ozon_metrics_by_cabinet_brand_month_cashflow_api.

-- ==== Ozon cash-flow: статьи с категорией (из канонических CTE) ====
CREATE VIEW IF NOT EXISTS ozon_cashflow_items_classified AS
WITH duplicated_items AS (
    SELECT DISTINCT l.cabinet, l.period_begin, l.item_name
    FROM (
        SELECT cabinet, period_begin, item_name FROM ozon_cashflow_items FINAL
        WHERE bucket IN ('delivery_services', 'return_services')
    ) l
    INNER JOIN (
        SELECT cabinet, period_begin, item_name FROM ozon_cashflow_items FINAL
        WHERE bucket IN ('services', 'others')
    ) o
    ON l.cabinet = o.cabinet AND l.period_begin = o.period_begin AND l.item_name = o.item_name
),
items_classified AS (
    SELECT
        cabinet,
        toStartOfMonth(period_begin) AS month,
        item_name AS item_name,
        multiIf(
            item_name IN ('MarketplaceServiceItemDirectFlowLogistic','MarketplaceServiceItemDirectFlowLogisticSum','MarketplaceServiceItemDeliveryToHandoverPlaceOzon','MarketplaceServiceItemReturnFlowLogistic','MarketplaceServiceItemReturnNotDelivToCustomer','MarketplaceServiceItemReturnAfterDelivToCustomer','MarketplaceServiceItemDropoff','MarketplaceServiceItemRedistributionDropoff'), 'logistics',
            item_name IN ('MarketplaceServiceItemRedistributionLastMileCourier','MarketplaceServiceItemRedistributionLastMilePVZ','MarketplaceServiceItemRedistributionReturnsPVZ','MarketplaceRedistributionOfAcquiringItem'), 'last_mile',
            item_name IN ('MarketplaceServiceItemFlexiblePaymentSchedule','MarketplaceServiceEarlyPayment','MarketplaceServiceItemPackageMaterialsProvision','MarketplaceElectronicServiceItemTransferringCards','FinesErrorIndexExceeded','MarketplaceProductDisposal','FinesProhibitedProducts','MarketplaceServiceItemDefectRateDetailed'), 'fines',
            item_name IN ('MarketplaceSellerDecompensationItemByTypeDocOperation','AccrualInternalClaim','AccrualConsigWriteOff','AccrualConsigDefectiveWriteOff','AccrualWithoutDocs'), 'surcharges',
            item_name IN ('MarketplaceServiceItemElectronicServicePinReview','MarketplaceServiceCostPerClick','MarketplaceServiceItemSubscriptionPremiumPlus','MarketplaceServiceItemSubscriptionPremiumPro','MarketplaceServiceItemPremiumProMembership','MarketplaceServiceItemInternetSiteAdvertising','MarketplaceServicePromotionWithCostPerOrder','MarketplaceServiceBrandCommission','MarketplaceServiceBadgeBrandVerified','MarketplaceServiceBadgeOriginal','MarketplaceElectronicServiceAcceleratedProductReviews','MarketplaceElectronicServicePointforReviews','MarketplaceServiceItemElectronicServicesPremiumCashbackIndividualPoints'), 'promotion',
            item_name IN ('MarketplaceServiceItemCrossdocking','MarketplaceServiceProcessingNotIdentifiedSurplus','MarketplaceServiceItemSupplyInboundSupplySurplus','MarketplaceServiceItemSupplyInboundExpirationDateProcessing','MarketplaceServiceVolumeWeightCharacsProcessing','MarketplaceServiceStorageItem','MarketplaceServiceItemSupplyInboundCargoSurplus','MarketplaceServiceItemSupplyInboundCargoShortage','MarketplaceServiceItemSupplyInboundAdditional','MarketplaceServiceItemSupplyInboundSupplyShortage','MarketplaceServiceProductMovementFromWarehouse','MarketplaceServiceSellerReturnsCargoAssortment','MarketplaceServiceItemAdditionalPackagingAtWarehouse'), 'storage',
            item_name IN ('OperationSetOffBalance','MarketplaceSellerCorrectionOperation','MarketplaceCorrectionPointOperation','MarketplaceSellerReexposureDeliveryReturnOperation','OperationMarketplaceServicePartialCompensationToClient','InsuranceServiceSellerItem','MarketplaceServiceProcessingSpoilage'), 'other',
            item_name IN ('MarketplaceServiseItemAgencyFeeForSale', 'MarketplaceServiseItemPointsAwarded'), 'excluded',
            item_name LIKE '%RFBS%', 'excluded',
            'unmapped'
        ) AS category,
        price AS value
    FROM ozon_cashflow_items FINAL
    WHERE NOT (
        bucket IN ('services', 'others')
        AND (cabinet, period_begin, item_name) IN (SELECT cabinet, period_begin, item_name FROM duplicated_items)
    )
)
SELECT cabinet, month, category, item_name, value FROM items_classified;

ALTER TABLE ozon_cashflow_items_classified COMMENT COLUMN category 'Категория канонической cash-flow-вьюхи: logistics, last_mile, fines, surcharges, storage, promotion, other; excluded — не входит в итог; unmapped — не распознано.';

-- ==== WB, из .xlsx ====
CREATE VIEW IF NOT EXISTS detail_adapter_wb AS
WITH
cs_k_types AS (
    SELECT arrayJoin(['продажа', 'сторно продаж', 'авансовая оплата за товар без движения', 'возврат', 'корректный возврат', 'корректная продажа', 'компенсация брака', 'компенсация потерянного товара', 'сторно возвратов', 'компенсация ущерба', 'добровольная компенсация при возврате', 'компенсация подмененного товара', 'частичная компенсация брака']) AS v
),
b AS (
    SELECT
        cabinet,
        if(lowerUTF8(trim(coalesce(brand, ''))) = '' OR lowerUTF8(trim(coalesce(brand, ''))) = 'неопознанный товар' OR lowerUTF8(trim(coalesce(brand, ''))) = lowerUTF8(cabinet), if(cabinet = 'CloudSix', 'Cloud Six', cabinet), trim(coalesce(brand, ''))) AS brand_key,
        formatDateTime(toStartOfMonth(sale_date), '%Y-%m') AS month,
        lowerUTF8(trim(coalesce(document_type, ''))) AS dt,
        lowerUTF8(trim(coalesce(payment_reason, ''))) AS pr_l,
        coalesce(nullIf(trim(payment_reason), ''), 'Без обоснования') AS pr,
        coalesce(nullIf(trim(logistics_fines_corrections_type), ''), 'Без типа операции') AS typ,
        trim(REGEXP_REPLACE(REGEXP_REPLACE(coalesce(logistics_fines_corrections_type, ''), ',\\s*документ\\s*№\\s*\\d+', ''), '\\s+\\d+$', '')) AS typ_clean,
        document_type,
        toFloat64(coalesce(payable_to_seller, 0)) AS payable_to_seller,
        toFloat64(coalesce(delivery_service_cost, 0)) AS delivery_service_cost,
        toFloat64(coalesce(total_fines, 0)) AS total_fines,
        toFloat64(coalesce(wb_commission_correction, 0)) AS wb_commission_correction,
        toFloat64(coalesce(storage_cost, 0)) AS storage_cost,
        toFloat64(coalesce(acceptance_operations, 0)) AS acceptance_operations,
        toFloat64(coalesce(deductions, 0)) AS deductions,
        toFloat64(coalesce(loyalty_program_cost, 0)) AS loyalty_program_cost,
        toFloat64(coalesce(loyalty_points_deducted, 0)) AS loyalty_points_deducted
    FROM wb_reports
    WHERE sale_date IS NOT NULL
)
SELECT
    cabinet AS cabinet, brand AS brand, month AS month, blk AS blk, grp AS grp, art AS art,
    toFloat64(amount) AS amount
FROM (
    SELECT cabinet, brand_key AS brand, month, '1 Начисления (сумма = К перечислению итого)' AS blk, t.1 AS grp, t.2 AS art, sum(t.3) AS amount
    FROM b
    ARRAY JOIN [
                (if(pr_l IN (SELECT v FROM cs_k_types), '01 К перечислению за товар', '02 Корректировки продаж'), pr, multiIf(dt = 'продажа', payable_to_seller, dt = 'возврат', -payable_to_seller, toFloat64(0))),
                ('03 Логистика', typ, -delivery_service_cost),
                ('04 Штрафы', typ, -total_fines),
                ('05 Доплаты (корректировка вознаграждения)', 'Корректировка вознаграждения WB', -wb_commission_correction),
                ('06 Хранение', 'Платное хранение', -storage_cost),
                ('07 Платная приёмка', 'Платная приёмка', -acceptance_operations),
                (if(typ_clean IN ('Оказание услуг «WB Продвижение»', 'Оказание услуг «ВБ.Продвижение»'), '09 Продвижение WB', '08 Удержания'), typ_clean, -deductions),
                ('10 Программа лояльности (Wibes)', 'Стоимость участия в программе лояльности', -loyalty_program_cost * if(document_type = 'Возврат', -1, 1)),
                ('10 Программа лояльности (Wibes)', 'Удержанные баллы лояльности', -loyalty_points_deducted * if(document_type = 'Возврат', -1, 1))
    ] AS t
    GROUP BY cabinet, brand, month, grp, art
    HAVING abs(amount) > 0
    UNION ALL
    SELECT cabinet, brand, formatDateTime(month, '%Y-%m') AS month, t.1 AS blk, t.2 AS grp, t.3 AS art, t.4 AS amount
    FROM wb_metrics_by_cabinet_brand_month
    ARRAY JOIN [('2 Выручка и комиссия (справочно)', '01 Продажи, СПП и комиссия WB', 'Продажи', toFloat64(sales_amount)), ('2 Выручка и комиссия (справочно)', '01 Продажи, СПП и комиссия WB', 'СПП', toFloat64(spp_amount)), ('2 Выручка и комиссия (справочно)', '01 Продажи, СПП и комиссия WB', 'Комиссия WB', toFloat64(wb_commission)), ('3 Количество, шт. (справочно)', '01 Продано за вычетом возвратов', 'Продано, шт.', toFloat64(sales_qty)), ('4 Себестоимость (справочно)', '01 Себестоимость проданного', 'Себестоимость', toFloat64(cogs)), ('5 Валовая прибыль (справочно)', '01 Валовая прибыль', 'Валовая прибыль', toFloat64(gross_profit)), ('6 Покрытие себестоимости, шт. (справочно)', '01 Покрытие справочником себестоимости', 'С себестоимостью, шт.', toFloat64(cogs_qty_covered)), ('6 Покрытие себестоимости, шт. (справочно)', '01 Покрытие справочником себестоимости', 'Без себестоимости, шт.', toFloat64(cogs_qty_uncovered))] AS t
);

ALTER TABLE detail_adapter_wb COMMENT COLUMN brand 'Бренд (по строке отчёта; пустой — название кабинета, CloudSix = «Cloud Six»).';
ALTER TABLE detail_adapter_wb COMMENT COLUMN blk 'Блок: «1 Начисления» аддитивен (сумма = К перечислению итого), остальные — справочные и не складываются с ним.';
ALTER TABLE detail_adapter_wb COMMENT COLUMN art 'Статья: значение поля отчёта WB — «Обоснование для оплаты» (К перечислению за товар) или «Тип операции» (логистика, штрафы, удержания).';

-- ==== WB, из API ====
CREATE VIEW IF NOT EXISTS detail_adapter_wb_api AS
WITH
cs_k_types AS (
    SELECT arrayJoin(['продажа', 'сторно продаж', 'авансовая оплата за товар без движения', 'возврат', 'корректный возврат', 'корректная продажа', 'компенсация брака', 'компенсация потерянного товара', 'сторно возвратов', 'компенсация ущерба', 'добровольная компенсация при возврате', 'компенсация подмененного товара', 'частичная компенсация брака']) AS v
),
b AS (
    SELECT
        cabinet,
        if(lowerUTF8(trim(coalesce(brand, ''))) = '' OR lowerUTF8(trim(coalesce(brand, ''))) = 'неопознанный товар' OR lowerUTF8(trim(coalesce(brand, ''))) = lowerUTF8(cabinet), if(cabinet = 'CloudSix', 'Cloud Six', cabinet), trim(coalesce(brand, ''))) AS brand_key,
        formatDateTime(toStartOfMonth(sale_date), '%Y-%m') AS month,
        lowerUTF8(trim(coalesce(document_type, ''))) AS dt,
        lowerUTF8(trim(coalesce(payment_reason, ''))) AS pr_l,
        coalesce(nullIf(trim(payment_reason), ''), 'Без обоснования') AS pr,
        coalesce(nullIf(trim(logistics_fines_corrections_type), ''), 'Без типа операции') AS typ,
        trim(REGEXP_REPLACE(REGEXP_REPLACE(coalesce(logistics_fines_corrections_type, ''), ',\\s*документ\\s*№\\s*\\d+', ''), '\\s+\\d+$', '')) AS typ_clean,
        document_type,
        toFloat64(coalesce(payable_to_seller, 0)) AS payable_to_seller,
        toFloat64(coalesce(delivery_service_cost, 0)) AS delivery_service_cost,
        toFloat64(coalesce(total_fines, 0)) AS total_fines,
        toFloat64(coalesce(wb_commission_correction, 0)) AS wb_commission_correction,
        toFloat64(coalesce(storage_cost, 0)) AS storage_cost,
        toFloat64(coalesce(acceptance_operations, 0)) AS acceptance_operations,
        toFloat64(coalesce(deductions, 0)) AS deductions,
        toFloat64(coalesce(loyalty_program_cost, 0)) AS loyalty_program_cost,
        toFloat64(coalesce(loyalty_points_deducted, 0)) AS loyalty_points_deducted
    FROM wb_api_realization_as_reports
    WHERE sale_date IS NOT NULL
)
SELECT
    cabinet AS cabinet, brand AS brand, month AS month, blk AS blk, grp AS grp, art AS art,
    toFloat64(amount) AS amount
FROM (
    SELECT cabinet, brand_key AS brand, month, '1 Начисления (сумма = К перечислению итого)' AS blk, t.1 AS grp, t.2 AS art, sum(t.3) AS amount
    FROM b
    ARRAY JOIN [
                (if(pr_l IN (SELECT v FROM cs_k_types), '01 К перечислению за товар', '02 Корректировки продаж'), pr, multiIf(dt = 'продажа', payable_to_seller, dt = 'возврат', -payable_to_seller, toFloat64(0))),
                ('03 Логистика', typ, -delivery_service_cost),
                ('04 Штрафы', typ, -total_fines),
                ('05 Доплаты (корректировка вознаграждения)', 'Корректировка вознаграждения WB', -wb_commission_correction),
                ('06 Хранение', 'Платное хранение', -storage_cost),
                ('07 Платная приёмка', 'Платная приёмка', -acceptance_operations),
                (if(typ_clean IN ('Оказание услуг «WB Продвижение»', 'Оказание услуг «ВБ.Продвижение»'), '09 Продвижение WB', '08 Удержания'), typ_clean, -deductions),
                ('10 Программа лояльности (Wibes)', 'Стоимость участия в программе лояльности', -loyalty_program_cost * if(document_type = 'Возврат', -1, 1)),
                ('10 Программа лояльности (Wibes)', 'Удержанные баллы лояльности', -loyalty_points_deducted * if(document_type = 'Возврат', -1, 1))
    ] AS t
    GROUP BY cabinet, brand, month, grp, art
    HAVING abs(amount) > 0
    UNION ALL
    SELECT cabinet, brand, formatDateTime(month, '%Y-%m') AS month, t.1 AS blk, t.2 AS grp, t.3 AS art, t.4 AS amount
    FROM wb_metrics_by_cabinet_brand_month_api
    ARRAY JOIN [('2 Выручка и комиссия (справочно)', '01 Продажи, СПП и комиссия WB', 'Продажи', toFloat64(sales_amount)), ('2 Выручка и комиссия (справочно)', '01 Продажи, СПП и комиссия WB', 'СПП', toFloat64(spp_amount)), ('2 Выручка и комиссия (справочно)', '01 Продажи, СПП и комиссия WB', 'Комиссия WB', toFloat64(wb_commission)), ('3 Количество, шт. (справочно)', '01 Продано за вычетом возвратов', 'Продано, шт.', toFloat64(sales_qty)), ('4 Себестоимость (справочно)', '01 Себестоимость проданного', 'Себестоимость', toFloat64(cogs)), ('5 Валовая прибыль (справочно)', '01 Валовая прибыль', 'Валовая прибыль', toFloat64(gross_profit)), ('6 Покрытие себестоимости, шт. (справочно)', '01 Покрытие справочником себестоимости', 'С себестоимостью, шт.', toFloat64(cogs_qty_covered)), ('6 Покрытие себестоимости, шт. (справочно)', '01 Покрытие справочником себестоимости', 'Без себестоимости, шт.', toFloat64(cogs_qty_uncovered))] AS t
);

ALTER TABLE detail_adapter_wb_api COMMENT COLUMN brand 'Бренд (по строке отчёта; пустой — название кабинета, CloudSix = «Cloud Six»).';
ALTER TABLE detail_adapter_wb_api COMMENT COLUMN blk 'Блок: «1 Начисления» аддитивен (сумма = К перечислению итого), остальные — справочные и не складываются с ним.';
ALTER TABLE detail_adapter_wb_api COMMENT COLUMN art 'Статья: значение поля отчёта WB — «Обоснование для оплаты» (К перечислению за товар) или «Тип операции» (логистика, штрафы, удержания).';

-- ==== Ozon, из .xlsx ====
CREATE VIEW IF NOT EXISTS detail_adapter_ozon AS
WITH
raw AS (
    SELECT
        r.cabinet AS cabinet,
        formatDateTime(toStartOfMonth(r.accrual_date), '%Y-%m') AS month,
        multiIf(trim(r.service_group) = 'Продажи', '01 Продажи', trim(r.service_group) = 'Возвраты', '02 Возвраты', trim(r.service_group) = 'Вознаграждение Ozon', '03 Вознаграждение Ozon', trim(r.service_group) = 'Услуги доставки', '04 Услуги доставки', trim(r.service_group) = 'Услуги агентов', '05 Услуги агентов', trim(r.service_group) = 'Услуги партнёров', '06 Услуги партнёров', trim(r.service_group) = 'Услуги FBO', '07 Услуги FBO', trim(r.service_group) = 'Продвижение и реклама', '08 Продвижение и реклама', trim(r.service_group) = 'Другие услуги', '09 Другие услуги и штрафы', trim(r.service_group) = 'Другие услуги и штрафы', '09 Другие услуги и штрафы', trim(r.service_group) = 'Компенсации и декомпенсации', '10 Компенсации и декомпенсации', trim(r.service_group) = 'Прочие начисления', '11 Прочие начисления', concat('99 ', trim(r.service_group))) AS grp,
        coalesce(nullIf(trim(r.accrual_type), ''), 'Без типа') AS art,
        if(trim(coalesce(r.article, '')) = '', '', coalesce(nullIf(pb.brand_key, ''), if(r.cabinet = 'CloudSix', 'Cloud Six', r.cabinet))) AS brand_key,
        toFloat64(r.total_amount) AS amount
    FROM ozon_reports AS r
    LEFT JOIN ozon_product_brands AS pb
           ON pb.cabinet = r.cabinet AND pb.offer_key = lowerUTF8(trim(r.article))
    WHERE r.accrual_date IS NOT NULL
),
att AS (
    -- привязано к артикулу — на бренд артикула ТОЧНО
    SELECT cabinet, month, brand_key AS brand, grp, art, sum(amount) AS amount
    FROM raw WHERE brand_key != '' GROUP BY cabinet, month, brand_key, grp, art
),
un AS (
    -- начисления без артикула (Ozon относит на кабинет целиком) — раскладываются по выручке брендов
    SELECT cabinet, month, grp, art, sum(amount) AS amount
    FROM raw WHERE brand_key = '' GROUP BY cabinet, month, grp, art
),
w AS (
    -- веса раскладки = выручка брендов из КАНОНИЧЕСКОЙ sku-вьюхи (дёшево); совпадают с выручкой в
    -- ozon_metrics_by_cabinet_brand_month, откуда считаются справочные блоки ниже
    SELECT k.cabinet AS cabinet, formatDateTime(k.month, '%Y-%m') AS month,
           coalesce(nullIf(pb.brand_key, ''), if(k.cabinet = 'CloudSix', 'Cloud Six', k.cabinet)) AS brand, greatest(sum(k.sales_amount), 0) AS w
    FROM ozon_metrics_by_sku_month AS k
    LEFT JOIN ozon_product_brands AS pb ON pb.cabinet = k.cabinet AND pb.offer_key = lowerUTF8(trim(k.sku))
    WHERE k.sku != 'без артикула'
    GROUP BY cabinet, month, brand
),
wt AS (
    SELECT cabinet, month, sum(w) AS wsum FROM w GROUP BY cabinet, month
),
recv AS (
    SELECT w.cabinet AS cabinet, w.month AS month, w.brand AS brand, w.w / wt.wsum AS share
    FROM w INNER JOIN wt ON wt.cabinet = w.cabinet AND wt.month = w.month
    WHERE wt.wsum > 0
    UNION ALL
    SELECT u.cabinet AS cabinet, u.month AS month, if(u.cabinet = 'CloudSix', 'Cloud Six', u.cabinet) AS brand, toFloat64(1) AS share
    FROM (SELECT DISTINCT cabinet, month FROM un) AS u
    LEFT JOIN wt ON wt.cabinet = u.cabinet AND wt.month = u.month
    WHERE coalesce(wt.wsum, 0) = 0
),
accr AS (
    SELECT cabinet, brand, month, grp, art, amount FROM att
    UNION ALL
    SELECT u.cabinet AS cabinet, r.brand AS brand, u.month AS month, u.grp AS grp, u.art AS art,
           u.amount * r.share AS amount
    FROM un AS u INNER JOIN recv AS r ON r.cabinet = u.cabinet AND r.month = u.month
)
SELECT cabinet AS cabinet, brand AS brand, month AS month, blk AS blk, grp AS grp, art AS art, toFloat64(amount) AS amount
FROM (
    SELECT cabinet, brand, month, '1 Начисления (сумма = К перечислению итого)' AS blk, grp, art, sum(amount) AS amount
    FROM accr GROUP BY cabinet, brand, month, grp, art HAVING abs(amount) > 0
    UNION ALL
    SELECT cabinet, brand, formatDateTime(month, '%Y-%m') AS month, t.1 AS blk, t.2 AS grp, t.3 AS art, t.4 AS amount
    FROM ozon_metrics_by_cabinet_brand_month
    ARRAY JOIN [('3 Количество, шт. (справочно)', '01 Продано за вычетом возвратов', 'Продано, шт.', toFloat64(sales_qty)),
                ('4 Себестоимость (справочно)', '01 Себестоимость проданного', 'Себестоимость', toFloat64(cogs)),
                ('5 Валовая прибыль (справочно)', '01 Валовая прибыль', 'Валовая прибыль', toFloat64(gross_profit)),
                ('6 Покрытие себестоимости, шт. (справочно)', '01 Покрытие справочником себестоимости', 'С себестоимостью, шт.', toFloat64(cogs_qty_covered)),
                ('6 Покрытие себестоимости, шт. (справочно)', '01 Покрытие справочником себестоимости', 'Без себестоимости, шт.', toFloat64(cogs_qty_uncovered))] AS t
);

ALTER TABLE detail_adapter_ozon COMMENT COLUMN art 'Статья = тип начисления отчёта Ozon (.xlsx «Начисления»); группа = группа услуг отчёта. Начисления без артикула разложены по брендам пропорционально выручке (оценка).';

-- ==== Ozon, из API ====
CREATE VIEW IF NOT EXISTS detail_adapter_ozon_api AS
WITH
cf AS (
    SELECT cabinet, formatDateTime(month, '%Y-%m') AS month, category, item_name, value
    FROM ozon_cashflow_items_classified
),
c AS (
    SELECT cabinet, formatDateTime(month, '%Y-%m') AS month, brand, share, payable_for_goods, payable_total
    FROM ozon_metrics_by_cabinet_brand_month_cashflow_api
),
r AS (
    SELECT cabinet, formatDateTime(month, '%Y-%m') AS month, brand, sales_qty, sales_amount, spp_amount, commission,
           returns_corrections, cogs, cogs_qty_covered, cogs_qty_uncovered
    FROM ozon_realization_by_cabinet_brand_month
)
SELECT cabinet AS cabinet, brand AS brand, month AS month, blk AS blk, grp AS grp, art AS art, toFloat64(amount) AS amount
FROM (
    -- «К перечислению за товар» по бренду — ТОЧНО из реализации (совпадает с cash-flow до рубля)
    SELECT cabinet, brand, month, '1 Начисления (сумма = К перечислению итого)' AS blk, '01 К перечислению за товар' AS grp,
           'К перечислению за товар' AS art, payable_for_goods AS amount
    FROM c
    UNION ALL
    -- расходы кабинета по статьям cash-flow — по доле выручки бренда (оценка)
    SELECT c.cabinet AS cabinet, c.brand AS brand, c.month AS month, '1 Начисления (сумма = К перечислению итого)' AS blk,
           multiIf(category = 'logistics', '02 Логистика', category = 'last_mile', '03 Последняя миля и партнёрские услуги', category = 'fines', '04 Штрафы и прочие услуги', category = 'surcharges', '05 Доплаты и компенсации', category = 'storage', '06 Хранение и услуги FBO', category = 'promotion', '07 Продвижение и реклама', category = 'other', '08 Прочие начисления', '99 Прочее') AS grp, if(has(['MarketplaceServiceItemDirectFlowLogisticSum', 'MarketplaceServiceItemRedistributionLastMileCourier', 'MarketplaceServiceItemDeliveryToHandoverPlaceOzon', 'MarketplaceServiceItemRedistributionLastMilePVZ', 'MarketplaceServiceItemRedistributionDropoff', 'MarketplaceServiceItemDropoff', 'MarketplaceServiceItemReturnFlowLogistic', 'MarketplaceServiceItemRedistributionReturnsPVZ', 'MarketplaceServiseItemPointsAwarded', 'MarketplaceServiceCostPerClick', 'MarketplaceServicePromotionWithCostPerOrder', 'MarketplaceServiseItemAgencyFeeForSale', 'MarketplaceRedistributionOfAcquiringItem', 'MarketplaceServiceItemFlexiblePaymentSchedule', 'MarketplaceServiceBrandCommission', 'MarketplaceServiceStorageItem', 'MarketplaceElectronicServiceItemTransferringCards', 'MarketplaceServiceItemCrossdocking', 'MarketplaceServiceItemSubscriptionPremiumPlus', 'InsuranceServiceSellerItem', 'MarketplaceServiceItemElectronicServicePinReview', 'MarketplaceServiceEarlyPayment', 'MarketplaceServiceRedistributionOfDeliveryServicesRFBS', 'FinesErrorIndexExceeded', 'MarketplaceServiceSellerReturnsCargoAssortment', 'MarketplaceServiceProductMovementFromWarehouse', 'MarketplaceServiceItemSupplyInboundAdditional', 'MarketplaceElectronicServicePointforReviews', 'MarketplaceServiceBadgeOriginal', 'MarketplaceServiceItemElectronicServicesPremiumCashbackIndividualPoints', 'MarketplaceServiceItemInternetSiteAdvertising', 'MarketplaceSellerCorrectionOperation', 'MarketplaceServiceBadgeBrandVerified', 'MarketplaceServiceItemTransferringCards', 'MarketplaceServiceItemPremiumProMembership', 'MarketplaceServiceItemPackageMaterialsProvision', 'MarketplaceElectronicServiceAcceleratedProductReviews', 'MarketplaceServiceItemSupplyInboundCargoShortage', 'MarketplaceServiceItemDefectRateDetailed', 'MarketplaceServiceItemSubscriptionPremiumPro', 'MarketplaceServiceItemTemporaryStorageRedistribution', 'MarketplaceServiceItemServiceFeeRFBS', 'MarketplaceProductDisposal', 'MarketplaceServiceItemSupplyInboundExpirationDateProcessing', 'MarketplaceServiceItemSupplyInboundCargoSurplus', 'MarketplaceServiceItemSupplyInboundSupplyShortage', 'MarketplaceAgencyFeeAggregator3plRFBS', 'MarketplaceServiceProcessingNotIdentifiedSurplus', 'MarketplaceServiceProcessingSpoilage', 'FinesProhibitedProducts', 'FinesProhibitedContent', 'MarketplaceServiceItemPackageRedistribution', 'MarketplaceServiceVolumeWeightCharacsProcessing', 'MarketplaceServiceItemAdditionalPackagingAtWarehouse', 'MarketplaceServiceItemDisposalDetailed', 'MarketplaceServiceItemSupplyInboundSupplySurplus', 'AccrualWithoutDocs', 'AccrualInternalClaim', 'AccrualConsigDefectiveWriteOff', 'MarketplaceRedistributionOfAcquiringOperation', 'MarketplaceSellerDecompensationItemByTypeDocOperation', 'MarketplaceSellerReexposureDeliveryReturnOperation', 'OperationMarketplaceServicePartialCompensationToClient', 'OperationSetOffBalance', 'MarketplaceCorrectionPointOperation', 'AccrualConsigWriteOff', 'MarketplaceServiceItemDirectFlowLogistic', 'MarketplaceServiceItemReturnAfterDelivToCustomer', 'MarketplaceServiceItemReturnNotDelivToCustomer'], item_name), arrayElement(['Логистика (прямой поток)', 'Последняя миля, курьер', 'Доставка до места выдачи силами Ozon', 'Последняя миля, ПВЗ', 'Drop-off, перераспределение', 'Обработка отправления Drop-off', 'Обратная логистика', 'Возвраты, обработка в ПВЗ', 'Баллы за скидки (начислено)', 'Оплата за клик', 'Продвижение с оплатой за заказ', 'Агентское вознаграждение за продажу', 'Эквайринг', 'Гибкий график выплат', 'Продвижение бренда', 'Размещение на складе', 'Перенос карточек товаров (электронная услуга)', 'Кросс-докинг', 'Подписка Premium Plus', 'Страхование продавца', 'Закрепление отзыва', 'Досрочная выплата', 'Перераспределение услуг доставки realFBS', 'Штраф: превышение индекса ошибок', 'Возврат грузов продавцу (ассортимент)', 'Вывоз товара со склада', 'Дополнительные услуги приёмки поставки', 'Баллы за отзывы', 'Бейдж «Оригинал»', 'Premium: индивидуальный кешбэк баллами', 'Реклама в сети Интернет на сайте', 'Корректировка продавца', 'Бейдж «Проверенный бренд»', 'Перенос карточек товаров', 'Подписка Premium Pro', 'Обеспечение материалами для упаковки', 'Ускоренный сбор отзывов', 'Недостача грузомест при приёмке', 'Брак (детализация)', 'Подписка Premium Pro (процент)', 'Временное размещение товара', 'Сервисный сбор realFBS', 'Утилизация товара', 'Обработка срока годности', 'Излишки грузомест при приёмке', 'Недостача поставки при приёмке', 'Агентское вознаграждение агрегатора realFBS', 'Обработка неопознанных излишков', 'Обработка брака', 'Штраф: запрещённый товар', 'Штраф: запрещённый контент', 'Упаковка товара (перераспределение)', 'Обработка объёмно-весовых характеристик', 'Дополнительная упаковка на складе', 'Утилизация (детализация)', 'Излишки поставки при приёмке', 'Начисления без документов', 'Внутренние претензии', 'Списание брака (консигнация)', 'Эквайринг (операция)', 'Декомпенсации по типам документов', 'Повторное выставление доставки/возврата', 'Частичные компенсации покупателям', 'Взаимозачёт по балансу', 'Корректировка баллов', 'Списание (консигнация)', 'Логистика (прямой поток, детально)', 'Возврат после доставки покупателю', 'Возврат недоставленного покупателю'], indexOf(['MarketplaceServiceItemDirectFlowLogisticSum', 'MarketplaceServiceItemRedistributionLastMileCourier', 'MarketplaceServiceItemDeliveryToHandoverPlaceOzon', 'MarketplaceServiceItemRedistributionLastMilePVZ', 'MarketplaceServiceItemRedistributionDropoff', 'MarketplaceServiceItemDropoff', 'MarketplaceServiceItemReturnFlowLogistic', 'MarketplaceServiceItemRedistributionReturnsPVZ', 'MarketplaceServiseItemPointsAwarded', 'MarketplaceServiceCostPerClick', 'MarketplaceServicePromotionWithCostPerOrder', 'MarketplaceServiseItemAgencyFeeForSale', 'MarketplaceRedistributionOfAcquiringItem', 'MarketplaceServiceItemFlexiblePaymentSchedule', 'MarketplaceServiceBrandCommission', 'MarketplaceServiceStorageItem', 'MarketplaceElectronicServiceItemTransferringCards', 'MarketplaceServiceItemCrossdocking', 'MarketplaceServiceItemSubscriptionPremiumPlus', 'InsuranceServiceSellerItem', 'MarketplaceServiceItemElectronicServicePinReview', 'MarketplaceServiceEarlyPayment', 'MarketplaceServiceRedistributionOfDeliveryServicesRFBS', 'FinesErrorIndexExceeded', 'MarketplaceServiceSellerReturnsCargoAssortment', 'MarketplaceServiceProductMovementFromWarehouse', 'MarketplaceServiceItemSupplyInboundAdditional', 'MarketplaceElectronicServicePointforReviews', 'MarketplaceServiceBadgeOriginal', 'MarketplaceServiceItemElectronicServicesPremiumCashbackIndividualPoints', 'MarketplaceServiceItemInternetSiteAdvertising', 'MarketplaceSellerCorrectionOperation', 'MarketplaceServiceBadgeBrandVerified', 'MarketplaceServiceItemTransferringCards', 'MarketplaceServiceItemPremiumProMembership', 'MarketplaceServiceItemPackageMaterialsProvision', 'MarketplaceElectronicServiceAcceleratedProductReviews', 'MarketplaceServiceItemSupplyInboundCargoShortage', 'MarketplaceServiceItemDefectRateDetailed', 'MarketplaceServiceItemSubscriptionPremiumPro', 'MarketplaceServiceItemTemporaryStorageRedistribution', 'MarketplaceServiceItemServiceFeeRFBS', 'MarketplaceProductDisposal', 'MarketplaceServiceItemSupplyInboundExpirationDateProcessing', 'MarketplaceServiceItemSupplyInboundCargoSurplus', 'MarketplaceServiceItemSupplyInboundSupplyShortage', 'MarketplaceAgencyFeeAggregator3plRFBS', 'MarketplaceServiceProcessingNotIdentifiedSurplus', 'MarketplaceServiceProcessingSpoilage', 'FinesProhibitedProducts', 'FinesProhibitedContent', 'MarketplaceServiceItemPackageRedistribution', 'MarketplaceServiceVolumeWeightCharacsProcessing', 'MarketplaceServiceItemAdditionalPackagingAtWarehouse', 'MarketplaceServiceItemDisposalDetailed', 'MarketplaceServiceItemSupplyInboundSupplySurplus', 'AccrualWithoutDocs', 'AccrualInternalClaim', 'AccrualConsigDefectiveWriteOff', 'MarketplaceRedistributionOfAcquiringOperation', 'MarketplaceSellerDecompensationItemByTypeDocOperation', 'MarketplaceSellerReexposureDeliveryReturnOperation', 'OperationMarketplaceServicePartialCompensationToClient', 'OperationSetOffBalance', 'MarketplaceCorrectionPointOperation', 'AccrualConsigWriteOff', 'MarketplaceServiceItemDirectFlowLogistic', 'MarketplaceServiceItemReturnAfterDelivToCustomer', 'MarketplaceServiceItemReturnNotDelivToCustomer'], item_name)), item_name) AS art, cf.value * c.share AS amount
    FROM cf INNER JOIN c ON c.cabinet = cf.cabinet AND c.month = cf.month
    WHERE cf.category IN ('logistics', 'last_mile', 'fines', 'surcharges', 'storage', 'promotion', 'other')
    UNION ALL
    -- статьи, исключённые из итога канонической вьюхи (двойной счёт / realFBS) и нераспознанные — справочно
    SELECT c.cabinet AS cabinet, c.brand AS brand, c.month AS month, '7 Не входит в итог (справочно)' AS blk,
           if(cf.category = 'excluded', '01 Исключено из итога (двойной счёт, realFBS)', '02 Не распознано каталогом') AS grp,
           if(has(['MarketplaceServiceItemDirectFlowLogisticSum', 'MarketplaceServiceItemRedistributionLastMileCourier', 'MarketplaceServiceItemDeliveryToHandoverPlaceOzon', 'MarketplaceServiceItemRedistributionLastMilePVZ', 'MarketplaceServiceItemRedistributionDropoff', 'MarketplaceServiceItemDropoff', 'MarketplaceServiceItemReturnFlowLogistic', 'MarketplaceServiceItemRedistributionReturnsPVZ', 'MarketplaceServiseItemPointsAwarded', 'MarketplaceServiceCostPerClick', 'MarketplaceServicePromotionWithCostPerOrder', 'MarketplaceServiseItemAgencyFeeForSale', 'MarketplaceRedistributionOfAcquiringItem', 'MarketplaceServiceItemFlexiblePaymentSchedule', 'MarketplaceServiceBrandCommission', 'MarketplaceServiceStorageItem', 'MarketplaceElectronicServiceItemTransferringCards', 'MarketplaceServiceItemCrossdocking', 'MarketplaceServiceItemSubscriptionPremiumPlus', 'InsuranceServiceSellerItem', 'MarketplaceServiceItemElectronicServicePinReview', 'MarketplaceServiceEarlyPayment', 'MarketplaceServiceRedistributionOfDeliveryServicesRFBS', 'FinesErrorIndexExceeded', 'MarketplaceServiceSellerReturnsCargoAssortment', 'MarketplaceServiceProductMovementFromWarehouse', 'MarketplaceServiceItemSupplyInboundAdditional', 'MarketplaceElectronicServicePointforReviews', 'MarketplaceServiceBadgeOriginal', 'MarketplaceServiceItemElectronicServicesPremiumCashbackIndividualPoints', 'MarketplaceServiceItemInternetSiteAdvertising', 'MarketplaceSellerCorrectionOperation', 'MarketplaceServiceBadgeBrandVerified', 'MarketplaceServiceItemTransferringCards', 'MarketplaceServiceItemPremiumProMembership', 'MarketplaceServiceItemPackageMaterialsProvision', 'MarketplaceElectronicServiceAcceleratedProductReviews', 'MarketplaceServiceItemSupplyInboundCargoShortage', 'MarketplaceServiceItemDefectRateDetailed', 'MarketplaceServiceItemSubscriptionPremiumPro', 'MarketplaceServiceItemTemporaryStorageRedistribution', 'MarketplaceServiceItemServiceFeeRFBS', 'MarketplaceProductDisposal', 'MarketplaceServiceItemSupplyInboundExpirationDateProcessing', 'MarketplaceServiceItemSupplyInboundCargoSurplus', 'MarketplaceServiceItemSupplyInboundSupplyShortage', 'MarketplaceAgencyFeeAggregator3plRFBS', 'MarketplaceServiceProcessingNotIdentifiedSurplus', 'MarketplaceServiceProcessingSpoilage', 'FinesProhibitedProducts', 'FinesProhibitedContent', 'MarketplaceServiceItemPackageRedistribution', 'MarketplaceServiceVolumeWeightCharacsProcessing', 'MarketplaceServiceItemAdditionalPackagingAtWarehouse', 'MarketplaceServiceItemDisposalDetailed', 'MarketplaceServiceItemSupplyInboundSupplySurplus', 'AccrualWithoutDocs', 'AccrualInternalClaim', 'AccrualConsigDefectiveWriteOff', 'MarketplaceRedistributionOfAcquiringOperation', 'MarketplaceSellerDecompensationItemByTypeDocOperation', 'MarketplaceSellerReexposureDeliveryReturnOperation', 'OperationMarketplaceServicePartialCompensationToClient', 'OperationSetOffBalance', 'MarketplaceCorrectionPointOperation', 'AccrualConsigWriteOff', 'MarketplaceServiceItemDirectFlowLogistic', 'MarketplaceServiceItemReturnAfterDelivToCustomer', 'MarketplaceServiceItemReturnNotDelivToCustomer'], item_name), arrayElement(['Логистика (прямой поток)', 'Последняя миля, курьер', 'Доставка до места выдачи силами Ozon', 'Последняя миля, ПВЗ', 'Drop-off, перераспределение', 'Обработка отправления Drop-off', 'Обратная логистика', 'Возвраты, обработка в ПВЗ', 'Баллы за скидки (начислено)', 'Оплата за клик', 'Продвижение с оплатой за заказ', 'Агентское вознаграждение за продажу', 'Эквайринг', 'Гибкий график выплат', 'Продвижение бренда', 'Размещение на складе', 'Перенос карточек товаров (электронная услуга)', 'Кросс-докинг', 'Подписка Premium Plus', 'Страхование продавца', 'Закрепление отзыва', 'Досрочная выплата', 'Перераспределение услуг доставки realFBS', 'Штраф: превышение индекса ошибок', 'Возврат грузов продавцу (ассортимент)', 'Вывоз товара со склада', 'Дополнительные услуги приёмки поставки', 'Баллы за отзывы', 'Бейдж «Оригинал»', 'Premium: индивидуальный кешбэк баллами', 'Реклама в сети Интернет на сайте', 'Корректировка продавца', 'Бейдж «Проверенный бренд»', 'Перенос карточек товаров', 'Подписка Premium Pro', 'Обеспечение материалами для упаковки', 'Ускоренный сбор отзывов', 'Недостача грузомест при приёмке', 'Брак (детализация)', 'Подписка Premium Pro (процент)', 'Временное размещение товара', 'Сервисный сбор realFBS', 'Утилизация товара', 'Обработка срока годности', 'Излишки грузомест при приёмке', 'Недостача поставки при приёмке', 'Агентское вознаграждение агрегатора realFBS', 'Обработка неопознанных излишков', 'Обработка брака', 'Штраф: запрещённый товар', 'Штраф: запрещённый контент', 'Упаковка товара (перераспределение)', 'Обработка объёмно-весовых характеристик', 'Дополнительная упаковка на складе', 'Утилизация (детализация)', 'Излишки поставки при приёмке', 'Начисления без документов', 'Внутренние претензии', 'Списание брака (консигнация)', 'Эквайринг (операция)', 'Декомпенсации по типам документов', 'Повторное выставление доставки/возврата', 'Частичные компенсации покупателям', 'Взаимозачёт по балансу', 'Корректировка баллов', 'Списание (консигнация)', 'Логистика (прямой поток, детально)', 'Возврат после доставки покупателю', 'Возврат недоставленного покупателю'], indexOf(['MarketplaceServiceItemDirectFlowLogisticSum', 'MarketplaceServiceItemRedistributionLastMileCourier', 'MarketplaceServiceItemDeliveryToHandoverPlaceOzon', 'MarketplaceServiceItemRedistributionLastMilePVZ', 'MarketplaceServiceItemRedistributionDropoff', 'MarketplaceServiceItemDropoff', 'MarketplaceServiceItemReturnFlowLogistic', 'MarketplaceServiceItemRedistributionReturnsPVZ', 'MarketplaceServiseItemPointsAwarded', 'MarketplaceServiceCostPerClick', 'MarketplaceServicePromotionWithCostPerOrder', 'MarketplaceServiseItemAgencyFeeForSale', 'MarketplaceRedistributionOfAcquiringItem', 'MarketplaceServiceItemFlexiblePaymentSchedule', 'MarketplaceServiceBrandCommission', 'MarketplaceServiceStorageItem', 'MarketplaceElectronicServiceItemTransferringCards', 'MarketplaceServiceItemCrossdocking', 'MarketplaceServiceItemSubscriptionPremiumPlus', 'InsuranceServiceSellerItem', 'MarketplaceServiceItemElectronicServicePinReview', 'MarketplaceServiceEarlyPayment', 'MarketplaceServiceRedistributionOfDeliveryServicesRFBS', 'FinesErrorIndexExceeded', 'MarketplaceServiceSellerReturnsCargoAssortment', 'MarketplaceServiceProductMovementFromWarehouse', 'MarketplaceServiceItemSupplyInboundAdditional', 'MarketplaceElectronicServicePointforReviews', 'MarketplaceServiceBadgeOriginal', 'MarketplaceServiceItemElectronicServicesPremiumCashbackIndividualPoints', 'MarketplaceServiceItemInternetSiteAdvertising', 'MarketplaceSellerCorrectionOperation', 'MarketplaceServiceBadgeBrandVerified', 'MarketplaceServiceItemTransferringCards', 'MarketplaceServiceItemPremiumProMembership', 'MarketplaceServiceItemPackageMaterialsProvision', 'MarketplaceElectronicServiceAcceleratedProductReviews', 'MarketplaceServiceItemSupplyInboundCargoShortage', 'MarketplaceServiceItemDefectRateDetailed', 'MarketplaceServiceItemSubscriptionPremiumPro', 'MarketplaceServiceItemTemporaryStorageRedistribution', 'MarketplaceServiceItemServiceFeeRFBS', 'MarketplaceProductDisposal', 'MarketplaceServiceItemSupplyInboundExpirationDateProcessing', 'MarketplaceServiceItemSupplyInboundCargoSurplus', 'MarketplaceServiceItemSupplyInboundSupplyShortage', 'MarketplaceAgencyFeeAggregator3plRFBS', 'MarketplaceServiceProcessingNotIdentifiedSurplus', 'MarketplaceServiceProcessingSpoilage', 'FinesProhibitedProducts', 'FinesProhibitedContent', 'MarketplaceServiceItemPackageRedistribution', 'MarketplaceServiceVolumeWeightCharacsProcessing', 'MarketplaceServiceItemAdditionalPackagingAtWarehouse', 'MarketplaceServiceItemDisposalDetailed', 'MarketplaceServiceItemSupplyInboundSupplySurplus', 'AccrualWithoutDocs', 'AccrualInternalClaim', 'AccrualConsigDefectiveWriteOff', 'MarketplaceRedistributionOfAcquiringOperation', 'MarketplaceSellerDecompensationItemByTypeDocOperation', 'MarketplaceSellerReexposureDeliveryReturnOperation', 'OperationMarketplaceServicePartialCompensationToClient', 'OperationSetOffBalance', 'MarketplaceCorrectionPointOperation', 'AccrualConsigWriteOff', 'MarketplaceServiceItemDirectFlowLogistic', 'MarketplaceServiceItemReturnAfterDelivToCustomer', 'MarketplaceServiceItemReturnNotDelivToCustomer'], item_name)), item_name) AS art, cf.value * c.share AS amount
    FROM cf INNER JOIN c ON c.cabinet = cf.cabinet AND c.month = cf.month
    WHERE cf.category IN ('excluded', 'unmapped')
    UNION ALL
    SELECT cabinet, brand, month, '2 Выручка и комиссия (справочно)' AS blk, '01 По отчёту о реализации' AS grp, t.1 AS art, t.2 AS amount
    FROM r
    ARRAY JOIN [('Выручка', toFloat64(sales_amount)), ('СПП', toFloat64(spp_amount)),
                ('Комиссия', toFloat64(commission)),
                ('Корректировки, брак, потери и возвраты', toFloat64(returns_corrections))] AS t
    UNION ALL
    SELECT cabinet, brand, month, '3 Количество, шт. (справочно)' AS blk, '01 Продано за вычетом возвратов' AS grp,
           'Продано, шт.' AS art, toFloat64(sales_qty) AS amount
    FROM r
    UNION ALL
    SELECT cabinet, brand, month, '4 Себестоимость (справочно)' AS blk, '01 Себестоимость проданного' AS grp,
           'Себестоимость' AS art, toFloat64(cogs) AS amount
    FROM r
    UNION ALL
    -- валовая прибыль как в адаптере: итог к перечислению бренда + себестоимость
    SELECT c.cabinet AS cabinet, c.brand AS brand, c.month AS month, '5 Валовая прибыль (справочно)' AS blk, '01 Валовая прибыль' AS grp,
           'Валовая прибыль' AS art, c.payable_total + r.cogs AS amount
    FROM c INNER JOIN r ON r.cabinet = c.cabinet AND r.month = c.month AND r.brand = c.brand
    UNION ALL
    SELECT cabinet, brand, month, '6 Покрытие себестоимости, шт. (справочно)' AS blk, '01 Покрытие справочником себестоимости' AS grp,
           t.1 AS art, t.2 AS amount
    FROM r
    ARRAY JOIN [('С себестоимостью, шт.', toFloat64(cogs_qty_covered)),
                ('Без себестоимости, шт.', toFloat64(cogs_qty_uncovered))] AS t
);

ALTER TABLE detail_adapter_ozon_api COMMENT COLUMN art 'Статья cash-flow-statement Ozon с русским названием (переведено по смыслу кода). Расходы кабинета разложены по брендам пропорционально выручке бренда (оценка); «К перечислению за товар» — точно из реализации.';
