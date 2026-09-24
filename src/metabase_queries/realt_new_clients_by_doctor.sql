-- Metabase: native SQL карточка «Таблица - Реальт - Новые клиенты по
-- врачам» дашборда «Реальт - Визиты за 3 мес по врачам».
-- 2026-09-24. Это ЗНАМЕНАТЕЛЬ карточки realt_visits_3m_by_doctor.sql:
-- сколько новых клиентов клиники месяца M закрепилось за каждым врачом
-- (врач ПЕРВОГО визита клиента за всю историю). Нужна рядом с метрикой
-- «Визиты за 3 мес», чтобы видеть вес каждой ячейки: у врача с 1-2
-- новыми клиентами в месяце среднее число визитов статистически пустое,
-- а пустая ячейка в метрике = «новых клиентов не было», а не «ноль
-- визитов». Определение когорты, тип врача, ГОЧТЯ, детерминированный
-- tie-break и раскладка — ровно как в realt_visits_3m_by_doctor.sql,
-- см. подробную шапку там; здесь отличается только набор выводимых
-- колонок (count вместо ratio).
-- ОТЛИЧИЕ В СТРОКЕ-ЗАГОЛОВКЕ ГРУППЫ: в метрической карточке месячные
-- значения там пустые (усреднять ratio по группе врачей нельзя), а здесь
-- заполнены — это обычные счётчики клиентов, они складываются корректно,
-- и сумма по группам сходится с общим числом новых клиентов месяца.

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
),
doctors AS (
    -- Одна строка = один врач: 12 месячных значений + год.
    SELECT
        doc_group AS d_group,
        doc_ord   AS d_ord,
        doc_fio   AS d_fio,
        toFloat64(sumIf(new_clients, mnum = 1 )) AS m01,
        toFloat64(sumIf(new_clients, mnum = 2 )) AS m02,
        toFloat64(sumIf(new_clients, mnum = 3 )) AS m03,
        toFloat64(sumIf(new_clients, mnum = 4 )) AS m04,
        toFloat64(sumIf(new_clients, mnum = 5 )) AS m05,
        toFloat64(sumIf(new_clients, mnum = 6 )) AS m06,
        toFloat64(sumIf(new_clients, mnum = 7 )) AS m07,
        toFloat64(sumIf(new_clients, mnum = 8 )) AS m08,
        toFloat64(sumIf(new_clients, mnum = 9 )) AS m09,
        toFloat64(sumIf(new_clients, mnum = 10)) AS m10,
        toFloat64(sumIf(new_clients, mnum = 11)) AS m11,
        toFloat64(sumIf(new_clients, mnum = 12)) AS m12,
        toFloat64(sum(new_clients)) AS m_year
    FROM metric
    GROUP BY d_group, d_ord, d_fio
)
SELECT "Врач", "Янв", "Фев", "Мар", "Апр", "Май", "Июн", "Июл", "Авг", "Сен", "Окт", "Ноя", "Дек", "За год"
FROM (
    -- Строка-заголовок группы (см. РАСКЛАДКА в шапке).
    SELECT
        d_ord                 AS ord,
        0                     AS is_doc,
        upperUTF8(d_group)    AS "Врач",
        sum(m01) AS "Янв",
        sum(m02) AS "Фев",
        sum(m03) AS "Мар",
        sum(m04) AS "Апр",
        sum(m05) AS "Май",
        sum(m06) AS "Июн",
        sum(m07) AS "Июл",
        sum(m08) AS "Авг",
        sum(m09) AS "Сен",
        sum(m10) AS "Окт",
        sum(m11) AS "Ноя",
        sum(m12) AS "Дек",
        sum(m_year) AS "За год"
    FROM doctors
    GROUP BY ord, d_group
    UNION ALL
    SELECT
        d_ord, 1, d_fio,
        m01, m02, m03, m04, m05, m06, m07, m08, m09, m10, m11, m12,
        m_year
    FROM doctors
)
ORDER BY
    ord ASC,
    is_doc ASC,
    "За год" DESC,
    "Врач" ASC
SETTINGS query_plan_max_optimizations_to_apply = 100000
