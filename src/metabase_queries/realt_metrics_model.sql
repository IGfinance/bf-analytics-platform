-- Metabase: "Модель - Реальт метрики по месяцам" (id 98 в проде на 2026-09-15,
-- коллекция "Реальт" id 8, data source "ClickHouse Realt" id 3 → БД realt).
-- Сверяйтесь по имени, а не по id: id меняется, если модель пересоздать заново.
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
--
-- 2026-09-18: файл был не синхронизирован с продом — Илья добавил в саму
-- Model разбивку ФОТ по pay_type (Оклад+Бонус/Проценты, см. VIEW) и
-- "Прибыль после ФОТ" напрямую в Metabase, минуя репозиторий. Приведено в
-- соответствие с фактическим текстом Model 98 (проверено через API) +
-- добавлена "Выручка с первых визитов" (new_client_revenue).

SELECT
    month                     AS "Месяц",
    revenue                   AS "Выручка",
    visits                    AS "Визиты",
    clients                   AS "Клиенты",
    new_clients               AS "Новые клиенты",
    new_client_revenue        AS "Выручка с первых визитов",
    avg_check                 AS "Средний чек",
    fot_total                 AS "ФОТ всего",
    fot_psychiatrists         AS "ФОТ Психиатры",
    fot_psychologists         AS "ФОТ Психологи",
    fot_administrators        AS "ФОТ Администраторы",
    fot_management            AS "ФОТ Управление",
    fot_marketing             AS "ФОТ Маркетинг",
    fot_shmilovich            AS "ФОТ Шмилович",
    fot_taxes                 AS "Налоги и взносы с ФОТ",
    fot_revenue_share         AS "Доля ФОТ в выручке, %",
    revenue - fot_total + fot_taxes AS "Прибыль после ФОТ",
    fot_total_pct             AS "ФОТ всего — Проценты",
    fot_total_oklad           AS "ФОТ всего — Оклад+Бонус",
    fot_psychiatrists_pct     AS "ФОТ Психиатры — Проценты",
    fot_psychiatrists_oklad   AS "ФОТ Психиатры — Оклад+Бонус",
    fot_psychologists_pct     AS "ФОТ Психологи — Проценты",
    fot_psychologists_oklad   AS "ФОТ Психологи — Оклад+Бонус",
    fot_administrators_pct    AS "ФОТ Администраторы — Проценты",
    fot_administrators_oklad  AS "ФОТ Администраторы — Оклад+Бонус",
    fot_management_pct        AS "ФОТ Управление — Проценты",
    fot_management_oklad      AS "ФОТ Управление — Оклад+Бонус",
    fot_marketing_pct         AS "ФОТ Маркетинг — Проценты",
    fot_marketing_oklad       AS "ФОТ Маркетинг — Оклад+Бонус",
    fot_shmilovich_pct        AS "ФОТ Шмилович — Проценты",
    fot_shmilovich_oklad      AS "ФОТ Шмилович — Оклад+Бонус",
    fot_taxes_pct             AS "Налоги и взносы с ФОТ — Проценты",
    fot_taxes_oklad           AS "Налоги и взносы с ФОТ — Оклад+Бонус"
FROM realt_metrics_by_month
ORDER BY month
