-- Metabase: "Модель - Реальт выручка по услугам" (коллекция Реальта на
-- dashboards.finance-black.ru — сверяйтесь по имени, а не по id).
--
-- Тонкая обёртка над ClickHouse VIEW realt_revenue_by_service (см.
-- ../schema_realt_metrics_views.sql). Формулы — только в VIEW, здесь русские
-- подписи. Это минимальная метрика из ТЗ 02 («выручка по услугам»).
--
-- Фильтры те же, что в realt_metrics_by_month: сумма>0, исключены услуги
-- Шмиловича/Онегиной и исполнитель «тест». Строка = (месяц, услуга).
--
-- БД проекта Реальт в ClickHouse — `realt`. Про запрет native-переменных в
-- Metabase-модели — см. realt_metrics_model.sql.

SELECT
    month        AS "Месяц",
    service      AS "Услуга",
    revenue      AS "Выручка",
    visits       AS "Визиты",
    avg_check    AS "Средний чек"
FROM realt_revenue_by_service
ORDER BY month, revenue DESC
