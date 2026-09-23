-- Metabase: native SQL карточка дашборда «Когорты | Реальт», вкладка «ШАА»
-- — когорта по месяцу первого визита клиента × номер приёма, значение —
-- процент возвращаемости (% клиентов когорты, дошедших до этого приёма).
-- Визиты подразделения ШАА (Шмилович/Онегина) УЧТЕНЫ.

-- Парная карточка (та же логика, БЕЗ визитов ШАА):
-- realt_cohort_retention_without_shaa.sql, вкладка «Без ШАА» того же
-- дашборда. Переключатель ШАА сделан ВКЛАДКАМИ дашборда, не параметром —
-- номер приёма/когорта должны пересчитываться на разных наборах визитов,
-- см. следующий абзац.

-- Семантический слой: card_number/month/visit_start/role_group уже
-- посчитаны один раз в VIEW realt_visits_categorized (см.
-- schema_realt_metrics_views.sql) — здесь ПЕРЕИСПОЛЬЗУЮТСЯ как источник,
-- а не копируются заново. visit_seq/cohort_month из этой VIEW НЕ
-- переиспользуются напрямую — они всегда считают ПО ВСЕМ визитам
-- (включая ШАА), а парной карточке (без ШАА) нужна отдельная, заново
-- пересчитанная на отфильтрованном наборе последовательность — тот же
-- принцип, что у realt_metrics_by_month.new_clients (отдельная
-- последовательность без ШАА). Поэтому обе карточки пересчитывают
-- row_number/min заново из сырых полей, а не берут готовые visit_seq/
-- cohort_month.

-- ГОЧТЯ (найдено 2026-09-23): Metabase-постпроцессинг НАСТОЯЩЕГО
-- display=pivot ломается на native SQL (см. вики, гочтя про Metabase
-- pivot) — тихо без параметров ([0] вместо строк), с параметром явно
-- (500 "Ошибка генерации pivot-запросов"). Поэтому здесь display=table +
-- клиентский разворот table.pivot (visualization_settings) вместо
-- настоящего display=pivot — это ЧИСТО JS-разворот на фронте, серверный
-- pivot-постпроцессинг не задействуется вообще, поэтому параметры
-- (start_month/end_month ниже) работают нормально, как на любой обычной
-- native-SQL Таблице (ratio-карточки Юнит-экономики, тот же паттерн).

-- ПОЧЕМУ NATIVE-SQL «ТАБЛИЦА» НАПРЯМУЮ НА ДАШБОРДЕ, А НЕ MODEL (тонкая
-- обёртка): нужны параметры (start_month/end_month), а Metabase запрещает
-- переменные в карточках типа Model (проверено на WB/Ozon 2026-09-05, см.
-- шапку realt_metrics_model.sql). Тот же паттерн, что у ratio-карточек
-- Юнит-экономики.

-- Параметры (задел под start_month/end_month с дашборда id 10 —
-- виджет «Месяц и год», без дней; оба опциональны через блоки [[ ]],
-- пустой параметр = фильтр не применяется):
--   start_month/end_month: 'date/month-year' — режут ВЫВОД по
--   cohort_month, не влияют на сам расчёт номера приёма/когорты (тот
--   считается по полной истории клиента независимо от периода).

-- Задел на будущее (2026-09-23, по запросу владельца): фильтры по типу
-- врача (психиатр/психолог) и по ФИО врача — добавить тем же способом,
-- что doctor_type/doctor_name в realt_unitka_visits.sql. Пока не
-- добавлены.

-- MAX_VISIT_SEQ = 24 (захардкожено, не параметр) — без предела столбцов
-- было бы 162 (реальный максимум на проде 2026-09-23, редкие клиенты с
-- аномально частыми визитами), 90% визитов укладывается в первые 24 —
-- дальше таблица нечитаема. Ограничивает только ВЫВОД столбцов, «Размер
-- когорты» (знаменатель) считается по ВСЕМ визитам клиента независимо от
-- этого предела.

-- Формат «Мес» (месяц когорты) — Янв-22 (рус. сокращение месяца + 2 цифры
-- года), собран вручную через массив названий (ClickHouse formatDateTime
-- %b даёт английские сокращения, локализации под рус. нет).

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
    concat(
        ['Янв','Фев','Мар','Апр','Май','Июн','Июл','Авг','Сен','Окт','Ноя','Дек'][toMonth(r.cohort_month)],
        '-',
        substring(toString(toYear(r.cohort_month)), 3, 2)
    )                                                              AS "Мес",
    r.visit_seq                                                   AS "Номер приёма",
    round(r.clients_reached / nullIf(cs.cohort_size, 0) * 100, 1) AS "Возвращаемость, %",
    r.clients_reached                                             AS "Клиентов дошло",
    cs.cohort_size                                                AS "Размер когорты"
FROM reached r
JOIN cohort_sizes cs ON r.cohort_month = cs.cohort_month
WHERE 1 = 1
    [[ AND r.cohort_month >= {{start_month}} ]]
    [[ AND r.cohort_month < {{end_month}} + INTERVAL 1 MONTH ]]
ORDER BY r.cohort_month, r.visit_seq
