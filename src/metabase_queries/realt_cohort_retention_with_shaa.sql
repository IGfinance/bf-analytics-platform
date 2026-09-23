-- Metabase: native SQL карточка дашборда «Когорты | Реальт», вкладка
-- «Со ШАА» — когорта по месяцу первого визита клиента × номер приёма,
-- значение — процент возвращаемости (% клиентов когорты, дошедших до
-- этого приёма). Визиты подразделения ШАА (Шмилович/Онегина) УЧТЕНЫ.
--
-- Парная карточка (та же логика, БЕЗ визитов ШАА):
-- realt_cohort_retention_without_shaa.sql, вкладка «Без ШАА» того же
-- дашборда. Переключатель ШАА сделан ВКЛАДКАМИ дашборда, а не
-- Metabase-параметром — см. ГОЧТЯ ниже, почему.
--
-- Семантический слой: card_number/month/visit_start/role_group уже
-- посчитаны один раз в VIEW realt_visits_categorized (см.
-- schema_realt_metrics_views.sql) — здесь ПЕРЕИСПОЛЬЗУЮТСЯ как источник,
-- а не копируются заново. visit_seq/cohort_month из этой VIEW НЕ
-- переиспользуются напрямую — они всегда считают ПО ВСЕМ визитам
-- (включая ШАА), а второй карточке (без ШАА) нужна отдельная, заново
-- пересчитанная на отфильтрованном наборе последовательность — тот же
-- принцип, что у realt_metrics_by_month.new_clients (отдельная
-- последовательность без ШАА). Поэтому обе карточки пересчитывают
-- row_number/min заново из сырых полей, а не берут готовые visit_seq/
-- cohort_month.
--
-- ГОЧТЯ (найдено 2026-09-23): Metabase pivot-визуализация НЕ РАБОТАЕТ
-- вместе с native-SQL переменной ({{param}}) — запрос падает с "Ошибка
-- генерации pivot-запросов" / "мы получили больше параметров, чем можем
-- обработать" (проверено на этой же карточке с параметром include_shaa —
-- без параметра pivot отрабатывает нормально, с параметром — 500). Из-за
-- этого переключатель ШАА нельзя сделать Metabase-параметром на карточке
-- с pivot display (в отличие от ratio-карточек Юнит-экономики — те
-- display=table, не pivot). Решение — два отдельных файла/карточки без
-- параметров вообще, переключение вкладками дашборда.
--
-- ПОЧЕМУ NATIVE-SQL «ТАБЛИЦА» НАПРЯМУЮ НА ДАШБОРДЕ, А НЕ MODEL (тонкая
-- обёртка): было бы уместнее для parameterless-запроса завести чистую
-- VIEW + Model (общий принцип проекта), но обе карточки специально
-- держим как самостоятельные native SQL с идентичной структурой — чтобы
-- при будущем добавлении фильтров по типу/ФИО врача (см. ниже) не
-- пришлось переезжать с Model на native-SQL Таблицу задним числом (тот
-- же путь, что уже проделан для realt_unitka_visits.sql/
-- realt_unitka_clients.sql).
--
-- Задел на будущее (2026-09-23, по запросу владельца): фильтры по типу
-- врача (психиатр/психолог) и по ФИО врача — добавить тем же способом,
-- что doctor_type/doctor_name в realt_unitka_visits.sql, КОГДА карточка
-- будет display=table (не pivot) — см. ГОЧТЯ выше про несовместимость
-- параметров с pivot. Пока не добавлены.
--
-- MAX_VISIT_SEQ = 24 (захардкожено, не параметр) — без предела столбцов
-- было бы 162 (реальный максимум на проде 2026-09-23, редкие клиенты с
-- аномально частыми визитами), 90% визитов укладывается в первые 24 —
-- дальше таблица нечитаема. Ограничивает только ВЫВОД столбцов, «Размер
-- когорты» (знаменатель) считается по ВСЕМ визитам клиента независимо от
-- этого предела.

WITH base AS (
    SELECT
        card_number,
        month,
        visit_start
    FROM realt_visits_categorized
    -- ШАА учтены — без доп. фильтра по role_group
),
seq AS (
    SELECT
        card_number,
        row_number() OVER (PARTITION BY card_number ORDER BY visit_start) AS visit_seq,
        min(month) OVER (PARTITION BY card_number)                        AS cohort_month
    FROM base
),
cohort_sizes AS (
    SELECT cohort_month, uniqExact(card_number) AS cohort_size
    FROM seq
    GROUP BY cohort_month
),
reached AS (
    SELECT cohort_month, visit_seq, uniqExact(card_number) AS clients_reached
    FROM seq
    WHERE visit_seq <= 24
    GROUP BY cohort_month, visit_seq
)
SELECT
    r.cohort_month                                                AS "Месяц когорты",
    r.visit_seq                                                   AS "Номер приёма",
    round(r.clients_reached / nullIf(cs.cohort_size, 0) * 100, 1) AS "Возвращаемость, %",
    r.clients_reached                                             AS "Клиентов дошло",
    cs.cohort_size                                                AS "Размер когорты"
FROM reached r
JOIN cohort_sizes cs ON r.cohort_month = cs.cohort_month
ORDER BY r.cohort_month, r.visit_seq
