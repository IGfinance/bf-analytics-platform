-- VIEW-слой с теми же бизнес-формулами метрик, что ozon_metrics_by_cabinet_month
-- (см. schema_ozon_metrics_views.sql) и ozon_metrics_by_cabinet_month_api
-- (см. schema_ozon_metrics_views_api.sql), но посчитанный из НОВЫХ Ozon-методов
-- (/v1/finance/cash-flow-statement/list — ozon_cashflow_periods/ozon_cashflow_items,
-- см. schema_ozon_cashflow.sql), а не из мёртвого /v3/finance/transaction/list
-- (ozon_api_transactions). Нужен для постатейной сверки — см.
-- compare_ozon_cashflow_metrics.py (аналог compare_ozon_metrics.py для старого API).
--
-- Структурное отличие от старого API: cash-flow-statement НЕ разбивает
-- "выручка"/"комиссия"/"возврат" на отдельные числа — delivery.amount уже
-- "выручка минус базовая комиссия" одним числом (см. комментарий в
-- schema_ozon_cashflow.sql). Поэтому sales_with_spp/commission/returns_corrections
-- здесь НЕ выводятся по отдельности — только их сумма payable_for_goods
-- (=delivery.amount + return.amount), которая по формуле СОВПАДАЕТ с тем, как
-- payable_for_goods считается в обеих других моделях (sales + commission +
-- corrections). Это задокументированный пробел покрытия площадки, не ошибка
-- VIEW — см. врезку "три Ozon-метода" в docs/architecture-map.md.
--
-- Разбивка logistics/last_mile/fines/surcharges/promotion/storage/other строится
-- по item_name из ozon_cashflow_items — тот же глобальный каталог кодов услуг
-- Ozon, что и service_name/operation_type_name в старом API (переведено вручную
-- по смыслу английских кодов на русские названия из schema_ozon_metrics_views_api.sql,
-- где такой код совпадает по смыслу).
--
-- Проверено на реальных данных CloudSix (2026-09-23) против ozon_metrics_by_cabinet_month
-- за январь-май 2026 (полностью загруженный .xlsx): payable_for_goods,
-- logistics_cost, promotion_cost, storage_cost сходятся день-в-день или с
-- разницей на уровне рублей; last_mile_cost стабильно занижен на 2-4 тыс ₽/мес —
-- это тот же задокументированный пробел покрытия ("Упаковка товара партнёрами"/
-- "Временное размещение товара партнерами", FBO-поставочные сборы — см. врезку
-- "три Ozon-метода" в docs/architecture-map.md), отсутствующий во ВСЕХ новых
-- методах Ozon, не только здесь (см. unmapped ниже — 0 почти везде,
-- диагностика, что каталог кодов item_name учтён полностью).
--
-- Три поправки к сырым данным (loan, дубли статей логистики, агентские
-- аномалии AgencyFeeForSale/PointsAwarded) — те же, что в
-- ozon_cashflow_reconciled_month (см. schema_ozon_cashflow_reconciled.sql),
-- плюс исключены статьи с 'RFBS' в имени (rFBS сознательно не сверяется —
-- в .xlsx/старом API аналога нет вообще, см. тот же файл).

CREATE VIEW IF NOT EXISTS ozon_metrics_by_cabinet_month_cashflow_api AS
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
),
periods_agg AS (
    SELECT cabinet, toStartOfMonth(period_begin) AS month,
           sum(delivery_amount + return_amount) AS payable_for_goods
    FROM ozon_cashflow_periods FINAL
    GROUP BY cabinet, month
)
SELECT
    p.cabinet                                              AS cabinet,
    p.month                                                 AS month,
    p.payable_for_goods                                      AS payable_for_goods,
    sumIf(i.value, i.category = 'logistics')                  AS logistics_cost,
    sumIf(i.value, i.category = 'last_mile')                   AS last_mile_cost,
    sumIf(i.value, i.category = 'fines')                        AS fines,
    sumIf(i.value, i.category = 'surcharges')                    AS surcharges,
    sumIf(i.value, i.category = 'promotion')                      AS promotion_cost,
    sumIf(i.value, i.category = 'storage')                         AS storage_cost,
    sumIf(i.value, i.category = 'other')                            AS other_accruals,
    sumIf(i.value, i.category = 'unmapped')                          AS unmapped,
    p.payable_for_goods + sumIf(i.value, i.category NOT IN ('excluded', 'unmapped')) AS payable_total
FROM periods_agg p
LEFT JOIN items_classified i ON p.cabinet = i.cabinet AND p.month = i.month
GROUP BY p.cabinet, p.month, p.payable_for_goods
ORDER BY p.cabinet, p.month;

ALTER TABLE ozon_metrics_by_cabinet_month_cashflow_api COMMENT COLUMN unmapped 'Диагностическая колонка — сумма статей cash-flow-statement, не распознанных ни в один бакет (новый item_name, отсутствующий в CASE-маппинге). Должна быть 0 или близко к нулю; ненулевое значение — сигнал дописать маппинг в этом VIEW и в схожем месте compare_ozon_cashflow_metrics.py.';
ALTER TABLE ozon_metrics_by_cabinet_month_cashflow_api COMMENT COLUMN payable_for_goods 'delivery.amount + return.amount из cash-flow-statement — выручка за вычетом базовой комиссии, БЕЗ разбивки на sales_with_spp/commission/returns_corrections по отдельности (структурный пробел нового API, см. комментарий в начале файла). Сопоставима с payable_for_goods в ozon_metrics_by_cabinet_month/ozon_metrics_by_cabinet_month_api.';
ALTER TABLE ozon_metrics_by_cabinet_month_cashflow_api COMMENT COLUMN last_mile_cost 'Стабильно ниже, чем в .xlsx/старом API, на 2-4 тыс ₽/мес — статьи "Упаковка товара партнёрами"/"Временное размещение товара партнерами" (FBO-поставочные сборы) отсутствуют во всех новых Ozon-методах, задокументированный пробел покрытия площадки, не ошибка формулы.';
