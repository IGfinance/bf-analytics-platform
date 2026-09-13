-- VIEW-слой с теми же бизнес-формулами, что ozon_metrics_by_cabinet_month
-- (см. schema_ozon_metrics_views.sql), но посчитанный из ozon_api_transactions
-- (API-загрузка), а не из ozon_reports (ручная .xlsx-выгрузка). Нужен для
-- сверки метрик модели по двум независимым источникам — см. compare_ozon_metrics.py.
--
-- ozon_api_transactions устроена принципиально иначе, чем ozon_reports:
-- в .xlsx каждая строка — одна услуга/статья (service_group + accrual_type),
-- а в API одна строка — одна ОПЕРАЦИЯ (заказ/возврат/разовая услуга), где
-- у заказов и возвратов выручка+комиссия+логистика склеены в одну запись
-- (частично в отдельных полях accruals_for_sale/sale_commission, частично
-- в parallel-массивах service_names/service_prices). Поэтому колонки-бакеты
-- здесь собираются из трёх разных источников значений (ledger CTE ниже):
--
-- 1) "Разовые" операции (не заказ и не возврат) — их amount целиком
--    относится к одному бакету, категоризация по operation_type_name
--    (имя почти всегда совпадает или однозначно узнаётся по xlsx accrual_type,
--    сверено вручную по факту на реальных данных CloudSix 2026-09-13).
-- 2) Заказы/возвраты (OperationAgentDeliveredToCustomer, OperationItemReturn,
--    ClientReturnAgentOperation, OperationAgentStornoDeliveredToCustomer) —
--    accruals_for_sale идёт в sales (если type='orders') или в corrections
--    (если type='returns'), sale_commission — всегда в commission
--    (совпадает день-в-день с моделью вне зависимости от orders/returns).
-- 3) service_names/service_prices этих же заказов/возвратов, по одной
--    услуге на строку (ARRAY JOIN) — это логистика и последняя миля,
--    зашитые внутри операции, а не вынесенные отдельной строкой.
--
-- Проверено на реальных данных CloudSix (2026-09-13) за январь-май (за эти
-- месяцы .xlsx загружен полностью): ВСЕ метрики — sales_with_spp,
-- returns_corrections, commission, logistics_cost, last_mile_cost, fines,
-- surcharges, storage_cost, promotion_cost, other_accruals, payable_total —
-- совпадают с ozon_metrics_by_cabinet_month день-в-день (расхождение <1e-6 ₽).
--
-- Ловушка, из-за которой sales_with_spp/returns_corrections поначалу не
-- сходились (на 2025 ₽ в январе, 2450 ₽ в марте, 6643 ₽ в апреле, зеркально
-- между метриками): операция OperationAgentStornoDeliveredToCustomer
-- ("Доставка покупателю — отмена начисления") в API помечена type='returns',
-- что выглядит как повод отнести её в "Возвраты" — НО в .xlsx-выгрузке
-- Ozon сам кладёт соответствующие строки внутрь группы "Продажи" (как
-- отрицательные строки accrual_type Выручка/Баллы за скидки/Программы
-- партнёров, проверено построчно в ozon_reports). Источник истины —
-- поведение .xlsx, а не ярлык type из API: поэтому accruals_for_sale
-- этой операции ниже относится в бакет "sales", а не "corrections",
-- вопреки собственной категоризации API.
--
-- sales_amount/spp_amount по отдельности (как в ozon_reports-модели) здесь
-- НЕ выведены — у API нет отдельного поля под "Баллы за скидки", есть
-- только объединённая accruals_for_sale. Аналогично не выводится sales_qty
-- (нет прямого аналога qty из .xlsx на уровне операции).

CREATE VIEW IF NOT EXISTS ozon_metrics_by_cabinet_month_api AS
WITH standalone AS (
    SELECT
        cabinet,
        toStartOfMonth(toDate(addHours(operation_date, 3))) AS month,
        multiIf(
            operation_type_name IN ('Начисление за гибкий график выплат','Услуга досрочной выплаты','Обеспечение материалами для упаковки товара','Услуга за обработку операционных ошибок продавца: просроченная доставка','Перенос карточек товаров','Превышение индекса ошибок: отмена','Превышение индекса ошибок: просроченная отгрузка','Утилизация товара: Вы не забрали в срок','Утилизация товара: Повреждённые из-за упаковки','Утилизация товара: Повреждённые, были у покупателя','Утилизация товара','Запрещённый товар'), 'fines',
            operation_type_name IN ('Брак по вине Ozon на складе','Декомпенсации и возвращение товаров на сток','Начисление по спору','Потеря по вине Ozon в логистике','Потеря по вине Ozon на складе'), 'surcharges',
            operation_type_name IN ('Закрепление отзыва','Оплата за клик','Подписка Premium Plus','Продвижение бренда','Продвижение с оплатой за заказ','Реклама в сети Интернет на Сайте'), 'promotion',
            operation_type_name IN ('Взаимозачет требований между Договорами','Корректировки стоимости услуг','Корректировка суммы акта о премии','Перечисление за доставку от покупателя','Частичная компенсация покупателю','Страхование товара от массовых повреждений'), 'other',
            operation_type_name IN ('Услуга по бронированию места и персонала для поставки с неполным составом','Услуга по бронированию места и персонала для поставки с неполным составом в составе ГМ','Вывоз товара со Склада силами Ozon: Доставка до ПВЗ','Вывоз товара со Склада силами Ozon: Доставка до СЦ','Кросс-докинг','Обработка неопознанных излишков с приемки','Услуга по обработке опознанных излишков в составе ГМ','Обработка сроков годности на FBO','Обработка товара в составе грузоместа на FBO','Подготовка товара к вывозу: Брак','Подготовка товара к вывозу: Валид','Услуга размещения товаров на складе'), 'storage',
            operation_type_name = 'Сервисный сбор за интеграцию с логистической платформой', 'logistics',
            operation_type_name IN ('Временное размещение товара партнерами','Упаковка товара партнёрами','Оплата эквайринга'), 'last_mile',
            'unmapped'
        ) AS bucket,
        amount AS value
    FROM ozon_api_transactions FINAL
    WHERE operation_type NOT IN ('OperationAgentDeliveredToCustomer','OperationItemReturn','ClientReturnAgentOperation','OperationAgentStornoDeliveredToCustomer')
),
bundled_fields AS (
    SELECT cabinet, toStartOfMonth(toDate(addHours(operation_date, 3))) AS month, 'sales' AS bucket,
           if(operation_type IN ('OperationAgentDeliveredToCustomer','OperationAgentStornoDeliveredToCustomer'), accruals_for_sale, 0) AS value
    FROM ozon_api_transactions FINAL
    WHERE operation_type IN ('OperationAgentDeliveredToCustomer','OperationItemReturn','ClientReturnAgentOperation','OperationAgentStornoDeliveredToCustomer')
    UNION ALL
    SELECT cabinet, toStartOfMonth(toDate(addHours(operation_date, 3))) AS month, 'corrections' AS bucket,
           if(operation_type IN ('OperationItemReturn','ClientReturnAgentOperation'), accruals_for_sale, 0) AS value
    FROM ozon_api_transactions FINAL
    WHERE operation_type IN ('OperationAgentDeliveredToCustomer','OperationItemReturn','ClientReturnAgentOperation','OperationAgentStornoDeliveredToCustomer')
    UNION ALL
    SELECT cabinet, toStartOfMonth(toDate(addHours(operation_date, 3))) AS month, 'commission' AS bucket,
           sale_commission AS value
    FROM ozon_api_transactions FINAL
    WHERE operation_type IN ('OperationAgentDeliveredToCustomer','OperationItemReturn','ClientReturnAgentOperation','OperationAgentStornoDeliveredToCustomer')
    UNION ALL
    SELECT cabinet, toStartOfMonth(toDate(addHours(operation_date, 3))) AS month, 'logistics' AS bucket,
           (delivery_charge + return_delivery_charge) AS value
    FROM ozon_api_transactions FINAL
    WHERE operation_type IN ('OperationAgentDeliveredToCustomer','OperationItemReturn','ClientReturnAgentOperation','OperationAgentStornoDeliveredToCustomer')
),
bundled_services AS (
    SELECT
        cabinet,
        toStartOfMonth(toDate(addHours(operation_date, 3))) AS month,
        multiIf(
            service_name IN ('MarketplaceServiceItemDirectFlowLogistic','MarketplaceServiceItemDeliveryToHandoverPlaceOzon','MarketplaceServiceItemReturnFlowLogistic','MarketplaceServiceItemReturnNotDelivToCustomer','MarketplaceServiceItemReturnAfterDelivToCustomer'), 'logistics',
            service_name IN ('MarketplaceServiceItemRedistributionLastMileCourier','MarketplaceServiceItemRedistributionLastMilePVZ','MarketplaceServiceItemRedistributionReturnsPVZ'), 'last_mile',
            'unmapped'
        ) AS bucket,
        service_price AS value
    FROM ozon_api_transactions FINAL
    ARRAY JOIN service_names AS service_name, service_prices AS service_price
    WHERE operation_type IN ('OperationAgentDeliveredToCustomer','OperationItemReturn','ClientReturnAgentOperation','OperationAgentStornoDeliveredToCustomer')
),
ledger AS (
    SELECT * FROM standalone
    UNION ALL SELECT * FROM bundled_fields
    UNION ALL SELECT * FROM bundled_services
)
SELECT
    cabinet                                                            AS cabinet,
    month                                                               AS month,
    sumIf(value, bucket = 'sales')                                      AS sales_with_spp,
    sumIf(value, bucket = 'corrections')                                AS returns_corrections,
    sumIf(value, bucket = 'commission')                                 AS commission,
    (sumIf(value, bucket = 'sales') + sumIf(value, bucket = 'commission') + sumIf(value, bucket = 'corrections')) AS payable_for_goods,
    sumIf(value, bucket = 'logistics')                                  AS logistics_cost,
    sumIf(value, bucket = 'last_mile')                                  AS last_mile_cost,
    sumIf(value, bucket = 'fines')                                      AS fines,
    sumIf(value, bucket = 'surcharges')                                 AS surcharges,
    sumIf(value, bucket = 'storage')                                    AS storage_cost,
    sumIf(value, bucket = 'promotion')                                  AS promotion_cost,
    sumIf(value, bucket = 'other')                                      AS other_accruals,
    sumIf(value, bucket = 'unmapped')                                   AS unmapped,
    sum(value)                                                          AS payable_total
FROM ledger
GROUP BY cabinet, month
ORDER BY cabinet, month;

ALTER TABLE ozon_metrics_by_cabinet_month_api COMMENT COLUMN unmapped 'Диагностическая колонка — сумма операций/услуг, не распознанных ни в один бакет. Должна быть 0; ненулевое значение значит, что в API появился новый operation_type_name или service_name, которого нет в CASE-маппинге этого VIEW (сверьте с schema_ozon_metrics_views.sql и допишите маппинг).';
