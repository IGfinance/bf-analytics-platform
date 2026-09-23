-- Metabase: native SQL карточка дашборда «Когорты | Реальт», вкладка
-- «Без ШАА» — то же самое, что realt_cohort_retention_with_shaa.sql (см.
-- тот файл для полного описания логики/ГОЧТЯ/параметров), но визиты
-- подразделения ШАА (Шмилович/Онегина, role_group='ФОТ ШАА' в
-- realt_visits_categorized) ИСКЛЮЧЕНЫ — номер приёма и месяц когорты
-- пересчитаны заново на отфильтрованном наборе визитов клиента.

WITH base AS (
    SELECT
        card_number,
        month,
        visit_start
    FROM realt_visits_categorized
    WHERE role_group != 'ФОТ ШАА'
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
