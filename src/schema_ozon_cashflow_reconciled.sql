-- Помесячный "правильный" итог по ozon_cashflow_periods/ozon_cashflow_items —
-- формула проверена и сведена день-в-день с ozon_reports/ozon_api_transactions
-- на CloudSix (расхождение после применения всех трёх правок ниже — только
-- "Упаковка товара партнёрами"/"Временное размещение товара партнерами",
-- это FBO-поставочные сборы, которых физически нет ни в cash-flow-statement,
-- ни в accrual/postings — известный, задокументированный пробел покрытия).
--
-- Три поправки к сырым данным Ozon, все обнаружены и проверены на реальных
-- цифрах (см. историю разбора CloudSix):
--
-- 1) loan (займы/досрочные выплаты) — отдельный финансовый механизм
--    (аванс под будущие поступления), не начисление за товар/услуги.
--    Исключается целиком.
--
-- 2) MarketplaceServiseItemAgencyFeeForSale / MarketplaceServiseItemPointsAwarded
--    (да, опечатка "Servise" — так у Ozon) — появляются только с 2026-07,
--    суммы на порядок больше выручки периода, не имеют аналога в старых
--    данных. Похоже на отдельный (агентский?) учётный механизм, не деньги
--    к перечислению за этот период. Исключаются целиком.
--
-- 3) Задвоение между delivery_services/return_services и services/others:
--    один и тот же item_name с ОДИНАКОВОЙ суммой иногда встречается в ОБОИХ
--    местах одного периода (обнаружено на MarketplaceServiceItemDeliveryToHandoverPlaceOzon
--    с 2026-04) — Ozon дублирует статью в ответе API. delivery_total/return_total
--    её уже учитывают (через delivery_services/return_services.total), поэтому
--    вторую копию в services/others нужно вычесть. Правило общее (по совпадению
--    cabinet+period+item_name между бакетами), не привязано к конкретному имени —
--    задвоение может появиться и на других статьях позже.
--
-- rfbs_total сознательно НЕ включён — в старых данных (ozon_reports/
-- ozon_api_transactions) нет аналога вообще (проверено), суммы у CloudSix
-- незначительные. Если кабинет активно использует rFBS-схему доставки,
-- эту сумму стоит сверить отдельно, не через это view.

CREATE VIEW IF NOT EXISTS ozon_cashflow_reconciled_month AS
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
excluded_amounts AS (
    SELECT cabinet, period_begin, sum(price) AS excl_amount
    FROM ozon_cashflow_items FINAL
    WHERE bucket IN ('services', 'others')
      AND (
          item_name IN ('MarketplaceServiseItemAgencyFeeForSale', 'MarketplaceServiseItemPointsAwarded')
          OR (cabinet, period_begin, item_name) IN (SELECT cabinet, period_begin, item_name FROM duplicated_items)
      )
    GROUP BY cabinet, period_begin
)
SELECT
    p.cabinet AS cabinet,
    toStartOfMonth(p.period_begin) AS month,
    sum(p.delivery_total) AS delivery_total,
    sum(p.return_total) AS return_total,
    sum(p.services_total + p.others_total - coalesce(e.excl_amount, 0)) AS services_others_total,
    sum(p.delivery_total + p.return_total + p.services_total + p.others_total - coalesce(e.excl_amount, 0)) AS reconciled_total
FROM ozon_cashflow_periods p FINAL
LEFT JOIN excluded_amounts e ON p.cabinet = e.cabinet AND p.period_begin = e.period_begin
GROUP BY p.cabinet, month
ORDER BY p.cabinet, month;

ALTER TABLE ozon_cashflow_reconciled_month COMMENT COLUMN cabinet 'Кабинет Ozon (строка), связывается с project_cabinets.cabinet/brand_cabinets.cabinet при platform=''ozon''.';
ALTER TABLE ozon_cashflow_reconciled_month COMMENT COLUMN month 'Начало месяца — агрегация периодов выплат (~неделя) из /v1/finance/cash-flow-statement/list, попадающих в этот календарный месяц по дате начала периода.';
ALTER TABLE ozon_cashflow_reconciled_month COMMENT COLUMN delivery_total 'Выручка по доставкам за вычетом базовой комиссии Ozon и логистики доставки (delivery.total из cash-flow-statement = delivery.amount + delivery.delivery_services.total). Сходится день-в-день с operation_type=Доставка покупателю старой ozon_api_transactions.';
ALTER TABLE ozon_cashflow_reconciled_month COMMENT COLUMN return_total 'То же для возвратов (return.total), обычно отрицательное. Сходится день-в-день с operation_type=Получение возврата/Доставка и обработка возврата старой ozon_api_transactions.';
ALTER TABLE ozon_cashflow_reconciled_month COMMENT COLUMN services_others_total 'Реклама, подписки, хранение, компенсации и прочие account-level статьи (services.total + others.total), за вычетом loan, агентских аномалий AgencyFeeForSale/PointsAwarded и задвоенных статей логистики — см. комментарий в начале файла про все три поправки.';
ALTER TABLE ozon_cashflow_reconciled_month COMMENT COLUMN reconciled_total 'Итоговая сумма к перечислению за месяц (delivery_total + return_total + services_others_total). Сверена с ozon_reports/ozon_api_transactions на CloudSix — сходится до копеек, кроме задокументированного остатка (FBO-поставочные сборы "Упаковка/Временное размещение товара партнерами" — нет ни в одном новом Ozon-методе).';
