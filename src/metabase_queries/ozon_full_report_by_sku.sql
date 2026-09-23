-- Metabase: "Таблица - Полный отчет Ozon по артикулу (в строки)" (id 192) и
-- "Таблица - Полный отчет Ozon по артикулам (в строки)" (id 193) в проде на
-- 2026-09-23. Различаются ТОЛЬКО порядком сортировки (см. ORDER BY в конце):
-- первая — под визуал "показатели × месяцы" для одного артикула, вторая —
-- под визуал "артикулы × показатели" для сравнения артикулов за период.
--
-- Служебные Таблицы: готовят unpivot-данные для Визуалов и на дашборд сами
-- не выносятся (см. правило про Визуалы в .claude/knowledge/architecture-standarts.md).
-- Двухуровневая схема native SQL → MBQL-пивот обязательна: backend-пивот
-- Metabase не работает на чистом native SQL (см. чёрный список антипаттернов,
-- инцидент 2026-09-15).
--
-- Формулы не дублируются: все 17 показателей читаются готовыми колонками из
-- ozon_metrics_by_sku_month.

SELECT month, cabinet, sku, '01 Кол-во продаж' AS metric, toFloat64(sales_qty) AS value FROM ozon_metrics_by_sku_month
UNION ALL SELECT month, cabinet, sku, '02 Выручка + СПП' AS metric, toFloat64(sales_with_spp) AS value FROM ozon_metrics_by_sku_month
UNION ALL SELECT month, cabinet, sku, '03 Выручка' AS metric, toFloat64(sales_amount) AS value FROM ozon_metrics_by_sku_month
UNION ALL SELECT month, cabinet, sku, '04 СПП' AS metric, toFloat64(spp_amount) AS value FROM ozon_metrics_by_sku_month
UNION ALL SELECT month, cabinet, sku, '05 Комиссия' AS metric, toFloat64(commission) AS value FROM ozon_metrics_by_sku_month
UNION ALL SELECT month, cabinet, sku, '06 Корректировки, брак, потери и возвраты' AS metric, toFloat64(returns_corrections) AS value FROM ozon_metrics_by_sku_month
UNION ALL SELECT month, cabinet, sku, '07 К перечислению за товар' AS metric, toFloat64(payable_for_goods) AS value FROM ozon_metrics_by_sku_month
UNION ALL SELECT month, cabinet, sku, '08 Логистика' AS metric, toFloat64(logistics_cost) AS value FROM ozon_metrics_by_sku_month
UNION ALL SELECT month, cabinet, sku, '09 Последняя миля' AS metric, toFloat64(last_mile_cost) AS value FROM ozon_metrics_by_sku_month
UNION ALL SELECT month, cabinet, sku, '10 Штрафы' AS metric, toFloat64(fines) AS value FROM ozon_metrics_by_sku_month
UNION ALL SELECT month, cabinet, sku, '11 Доплаты' AS metric, toFloat64(surcharges) AS value FROM ozon_metrics_by_sku_month
UNION ALL SELECT month, cabinet, sku, '12 Хранение на складе' AS metric, toFloat64(storage_cost) AS value FROM ozon_metrics_by_sku_month
UNION ALL SELECT month, cabinet, sku, '13 Продвижение' AS metric, toFloat64(promotion_cost) AS value FROM ozon_metrics_by_sku_month
UNION ALL SELECT month, cabinet, sku, '14 Прочие начисления' AS metric, toFloat64(other_accruals) AS value FROM ozon_metrics_by_sku_month
UNION ALL SELECT month, cabinet, sku, '15 Выручка к перечислению' AS metric, toFloat64(payable_total) AS value FROM ozon_metrics_by_sku_month
UNION ALL SELECT month, cabinet, sku, '16 Себестоимость' AS metric, toFloat64(cogs) AS value FROM ozon_metrics_by_sku_month
UNION ALL SELECT month, cabinet, sku, '17 Валовая прибыль' AS metric, toFloat64(gross_profit) AS value FROM ozon_metrics_by_sku_month
ORDER BY month, cabinet, sku, metric
