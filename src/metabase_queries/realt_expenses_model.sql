-- Metabase: "Модель - Реальт расходы по типам" (коллекция "Реальт" на
-- dashboards.finance-black.ru — сверяйтесь по имени, а не по id).
--
-- Тонкая обёртка над ClickHouse VIEW realt_expenses_by_month (см.
-- ../schema_realt_metrics_views.sql). Формулы — только в VIEW, здесь русские
-- подписи. Строка = (месяц, тип статьи). Суммы отрицательные (расход).
--
-- «Без Шмиловича» — отдельная колонка amount_ex_shaa (единообразно с выручкой,
-- где Шмилович тоже исключён). БД проекта Реальт — realt (data source id 3).
-- Про запрет native-переменных в Metabase-модели — см. realt_metrics_model.sql.

SELECT
    month           AS "Месяц",
    expense_type    AS "Тип статьи",
    amount          AS "Расход (с Шмиловичем)",
    amount_ex_shaa  AS "Расход (без Шмиловича)",
    articles        AS "Статей в типе"
FROM realt_expenses_by_month
ORDER BY month, expense_type
