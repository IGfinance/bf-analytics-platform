-- Metabase: native SQL карточка «Таблица - Реальт - Новые клиенты по
-- врачам» дашборда «Реальт - Визиты за 3 мес по врачам».
-- 2026-09-24. Это ЗНАМЕНАТЕЛЬ карточки realt_visits_3m_by_doctor.sql:
-- сколько новых клиентов клиники месяца M закрепилось за каждым врачом
-- (врач ПЕРВОГО визита клиента за всю историю). Нужна рядом с метрикой
-- «Визиты за 3 мес», чтобы видеть вес каждой ячейки: у врача с 1-2
-- новыми клиентами в месяце среднее число визитов статистически пустое,
-- а пустая ячейка в метрике = «новых клиентов не было», а не «ноль
-- визитов». Определение когорты, тип врача, ГОЧТЯ, детерминированный
-- tie-break и группировка — ровно как в realt_visits_3m_by_doctor.sql,
-- см. подробную шапку там; здесь отличается только набор выводимых
-- колонок (count вместо ratio).

WITH
v AS (
    SELECT card_number, month, doctor_name, visit_start
    FROM realt_visits_categorized
),
doc_role AS (
    -- Роль врача по последнему периоду ФОТ (см. шапку: не role_group визита).
    SELECT employee_id, argMax(role, period) AS last_role
    FROM realt_payroll
    WHERE period IS NOT NULL
    GROUP BY employee_id
),
doc AS (
    -- doctor_name <-> employee_id в realt_visits_categorized 1:1 (проверено),
    -- max() здесь только чтобы снять NULL у врачей вне справочника.
    SELECT doctor_name, max(employee_id) AS employee_id
    FROM realt_visits_categorized
    GROUP BY doctor_name
),
doc_typed AS (
    SELECT
        d.doctor_name AS typed_doctor,
        multiIf(r.last_role IN ('ФОТ Психиатры', 'ФОТ Шмилович'), 'Психиатры',
                r.last_role = 'ФОТ Психологи',                    'Психологи',
                                                                  'Прочие') AS typed_group,
        multiIf(r.last_role IN ('ФОТ Психиатры', 'ФОТ Шмилович'), 1,
                r.last_role = 'ФОТ Психологи',                    2,
                                                                  3) AS typed_ord
    FROM doc AS d
    LEFT JOIN doc_role AS r ON d.employee_id = r.employee_id
),
first_visit AS (
    -- Первый визит клиента за всю историю + врач этого визита.
    -- Ключ argMin — ТУПЛ (visit_start, doctor_name): tie-break по ФИО
    -- делает выбор врача детерминированным (ГОЧТЯ 4 в шапке
    -- realt_visits_3m_by_doctor.sql — почему visit_seq тут не годится).
    SELECT
        card_number,
        argMin(month,       (visit_start, doctor_name)) AS acq_month,
        argMin(doctor_name, (visit_start, doctor_name)) AS acq_doctor
    FROM v
    GROUP BY card_number
),
cohort AS (
    SELECT card_number, acq_month, acq_doctor
    FROM first_visit
    WHERE toYear(acq_month) = toInt32({{year}})
),
per_client AS (
    -- Один проход: для каждого нового клиента — сколько его визитов К
    -- СВОЕМУ ЖЕ врачу попало в окно [M .. M+2 мес.]. Год визита НЕ
    -- фильтруется: у декабрьской когорты окно уходит в следующий год, и
    -- это правильно. LEFT JOIN (не INNER) — чтобы клиент не мог выпасть
    -- из знаменателя; его собственный первый визит всегда попадает в
    -- окно, поэтому pc_visits >= 1.
    SELECT
        c.acq_doctor         AS pc_doctor,
        toMonth(c.acq_month) AS pc_mnum,
        c.card_number        AS pc_card,
        countIf(v.month >= c.acq_month AND v.month < c.acq_month + INTERVAL 3 MONTH) AS pc_visits
    FROM cohort AS c
    LEFT JOIN v ON v.card_number = c.card_number AND v.doctor_name = c.acq_doctor
    GROUP BY pc_doctor, pc_mnum, pc_card
),
metric AS (
    SELECT
        t.typed_group   AS doc_group,
        t.typed_ord     AS doc_ord,
        p.pc_doctor     AS doc_fio,
        p.pc_mnum       AS mnum,
        count()         AS new_clients,
        sum(p.pc_visits) AS visits_3m
    FROM per_client AS p
    LEFT JOIN doc_typed AS t ON p.pc_doctor = t.typed_doctor
    GROUP BY doc_group, doc_ord, doc_fio, mnum
)
-- ГОЧТЯ GROUPING SETS в ClickHouse: у колонки, НЕ входящей в текущий
-- grouping set, тип становится Nullable и значение приходит NULL (а не
-- дефолтом типа) — поэтому подписи итоговых строк и ORDER BY идут через
-- coalesce() (подробнее — в realt_visits_3m_by_doctor.sql).
SELECT
    if(coalesce(doc_group, '') = '', 'ВСЯ КЛИНИКА', doc_group) AS "Тип",
    if(coalesce(doc_fio, '')   = '', 'ИТОГО',       doc_fio)   AS "Врач",
    toFloat64(sumIf(new_clients, mnum = 1 ))    AS "Янв",
    toFloat64(sumIf(new_clients, mnum = 2 ))    AS "Фев",
    toFloat64(sumIf(new_clients, mnum = 3 ))    AS "Мар",
    toFloat64(sumIf(new_clients, mnum = 4 ))    AS "Апр",
    toFloat64(sumIf(new_clients, mnum = 5 ))    AS "Май",
    toFloat64(sumIf(new_clients, mnum = 6 ))    AS "Июн",
    toFloat64(sumIf(new_clients, mnum = 7 ))    AS "Июл",
    toFloat64(sumIf(new_clients, mnum = 8 ))    AS "Авг",
    toFloat64(sumIf(new_clients, mnum = 9 ))    AS "Сен",
    toFloat64(sumIf(new_clients, mnum = 10))    AS "Окт",
    toFloat64(sumIf(new_clients, mnum = 11))    AS "Ноя",
    toFloat64(sumIf(new_clients, mnum = 12))    AS "Дек",
    toFloat64(sum(new_clients))                 AS "За год"
FROM metric
GROUP BY GROUPING SETS ((doc_ord, doc_group, doc_fio), (doc_ord, doc_group), ())
ORDER BY
    coalesce(doc_ord, 0) ASC,
    (coalesce(doc_fio, '') != '') ASC,
    "За год" DESC,
    "Врач" ASC
SETTINGS query_plan_max_optimizations_to_apply = 100000
