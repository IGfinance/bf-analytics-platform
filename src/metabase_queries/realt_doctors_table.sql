WITH
base AS (
    SELECT
        v.employee_id    AS employee_id,
        v.doctor_name    AS doctor_name,
        v.role_group     AS role_group,
        v.card_number    AS card_number,
        v.amount         AS amount,
        v.visit_seq      AS visit_seq,
        count(*) OVER (PARTITION BY v.card_number, v.month) AS mvisits
    FROM realt_visits_categorized v
    WHERE toYear(v.month) = toInt32({{year}})
      AND ( {{include_shaa}} = 'Да' OR v.role_group != 'ФОТ ШАА' )
      AND ( {{doctor_type}} = 'Все'
            OR ( {{doctor_type}} = 'Психиатрические' AND v.role_group IN ('ФОТ Психиатры', 'ФОТ ШАА') )
            OR ( {{doctor_type}} = 'Психологические' AND v.role_group = 'ФОТ Психологи' ) )
),
filtered AS (
    SELECT * FROM base
    WHERE ( {{client_type}} = 'Все'
            OR ( {{client_type}} = 'Первичный' AND mvisits = 1 )
            OR ( {{client_type}} = 'Повторный' AND mvisits >= 2 ) )
),
doctor_rev AS (
    SELECT
        employee_id, doctor_name, role_group,
        sum(amount)                              AS revenue,
        count()                                  AS visits,
        uniqExact(card_number)                   AS clients,
        uniqExactIf(card_number, visit_seq = 1)  AS new_clients
    FROM filtered
    GROUP BY employee_id, doctor_name, role_group
),
doctor_fot AS (
    SELECT
        employee_id,
        any(role_group)                                     AS doctor_role_group,
        sum(accrued_total)                                  AS fot,
        sum(coalesce(ndfl, 0) + coalesce(contributions, 0)) AS taxes
    FROM realt_payroll_categorized
    WHERE toYear(month) = toInt32({{year}})
      AND ( {{include_shaa}} = 'Да' OR role_group != 'ФОТ ШАА' )
      AND ( {{doctor_type}} = 'Все'
            OR ( {{doctor_type}} = 'Психиатрические' AND role_group IN ('ФОТ Психиатры', 'ФОТ ШАА') )
            OR ( {{doctor_type}} = 'Психологические' AND role_group = 'ФОТ Психологи' ) )
    GROUP BY employee_id
)
SELECT
    coalesce(r.doctor_name, dn.full_name)              AS "Врач",
    coalesce(r.role_group, f.doctor_role_group)        AS "Роль",
    toFloat64(r.revenue)                               AS "Выручка",
    toFloat64(r.visits)                                AS "Визиты",
    toFloat64(r.clients)                               AS "Клиенты",
    toFloat64(r.new_clients)                           AS "Новые клиенты",
    toFloat64(f.fot)                                   AS "ФОТ",
    toFloat64(r.revenue) / nullIf(toFloat64(r.visits), 0)   AS "Средний чек",
    toFloat64(f.fot) / nullIf(toFloat64(if({{unit}} = 'Клиент', r.clients, r.visits)), 0) AS "ФОТ на юнит",
    toFloat64(r.revenue) - coalesce(toFloat64(f.fot), 0) + coalesce(toFloat64(f.taxes), 0) AS "Прибыль после ФОТ"
FROM doctor_rev r
FULL OUTER JOIN doctor_fot f ON r.employee_id = f.employee_id
LEFT JOIN (SELECT employee_id, full_name FROM realt_employees FINAL WHERE full_name IS NOT NULL) dn
    ON coalesce(r.employee_id, f.employee_id) = dn.employee_id
ORDER BY "Выручка" DESC
