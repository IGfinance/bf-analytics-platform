-- Metabase: "Модель - Реальт метрики по месяцам" (коллекция Реальта на
-- dashboards.finance-black.ru — сверяйтесь по имени, а не по id: id меняется,
-- если модель пересоздать заново).
--
-- Аналог "Модель - WB метрики по кабинету и месяцу" (wb_metrics_model.sql) и
-- "Модель - Ozon метрики по кабинету и месяцу" (ozon_metrics_model.sql) — та же
-- роль: тонкая обёртка над ClickHouse VIEW (realt_metrics_by_month, см.
-- ../schema_realt_metrics_views.sql). Формулы считаются ТОЛЬКО в VIEW, здесь
-- лишь русские подписи колонок для дашборда.
-- См. «Семантический слой для AI-бота» в .claude/knowledge/architecture-standarts.md.
--
-- Формулы согласованы с логикой дашборда realt-bi (realt.garaev.tech/clinic):
-- revenue=SUM(amount), визиты=COUNT(*), клиент=Номер карты; исключены нулевые
-- суммы, услуги Шмиловича/Онегиной и исполнитель «тест». Когорта новых клиентов
-- считается по вычисленному номеру визита (row_number), а не по ненадёжной
-- колонке «Количество завершённых» — точнее, чем realt-bi (подробности в VIEW).
--
-- Согласовано с клиентом (2026-09-14): ФОТ = «Начислено ИТОГО»; доля ФОТ =
-- (ФОТ всего − ФОТ Шмилович) / выручка, т.к. выручка тоже без Шмиловича.
--
-- БД проекта Реальт в ClickHouse — `realt` (project_id=2). При создании модели
-- в Metabase выбирайте соответствующий data source / БД `realt`.
--
-- ВАЖНО (проверено на WB/Ozon 2026-09-05): Metabase запрещает переменные и
-- Field Filter в Модели, созданной из native SQL. Фильтры на дашборде — поверх
-- этой модели через GUI-вопросы, а не native-переменные здесь.

SELECT
    month                AS "Месяц",
    revenue              AS "Выручка",
    visits               AS "Визиты",
    clients              AS "Клиенты",
    new_clients          AS "Новые клиенты",
    avg_check            AS "Средний чек",
    fot_total            AS "ФОТ всего",
    fot_psychiatrists    AS "ФОТ Психиатры",
    fot_psychologists    AS "ФОТ Психологи",
    fot_administrators   AS "ФОТ Администраторы",
    fot_management       AS "ФОТ Управление",
    fot_marketing        AS "ФОТ Маркетинг",
    fot_shmilovich       AS "ФОТ Шмилович",
    fot_taxes            AS "Налоги и взносы с ФОТ",
    fot_revenue_share    AS "Доля ФОТ в выручке, %"
FROM realt_metrics_by_month
ORDER BY month
