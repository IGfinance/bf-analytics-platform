-- Metabase: native SQL карточки "Таблица - Реальт - Врачи (пофамильно)"
-- (id 184), дашборд "Помесячная юнитка (по врачам, корректная)" (id 7).
-- 2026-09-18: добавлен фильтр doctor_name (текстовая переменная, ''=все
-- врачи) — дашборд-фильтр «Врач» подключён и сюда, и к помесячному пивоту
-- (realt_unitka_by_doctor.sql), значения берутся из отдельной карточки
-- "Таблица - Реальт - Список врачей (справочник фильтра)" (id 185,
-- DISTINCT doctor_name FROM realt_doctor_month) через
-- values_source_type=card дашборд-параметра — обновляется сама по мере
-- появления новых врачей, руками список поддерживать не нужно.
-- doctor_fot фильтруется по employee_id (в realt_payroll_categorized нет
-- doctor_name) через подзапрос к realt_employees по совпадению full_name.
-- ГОЧТЯ (проверено эмпирически 2026-09-18): голая строка-комментарий "--"
-- без пробела/текста после ломает разбор параметров в ClickHouse
-- JDBC-драйвере Metabase ("Похоже, мы получили больше параметров, чем
-- можем обработать") — не связано с содержимым комментария, дело именно
-- в пустой "--" самой по себе. После "--" всегда должен идти пробел или
-- текст, пустых строк-разделителей в этом файле больше нет намеренно.
WITH
base AS (
    SELECT
        v.employee_id    AS employee_id,
        v.doctor_name    AS doctor_name,
        v.role_group     AS role_group,
        v.visit_floor    AS visit_floor,
        v.card_number    AS card_number,
        v.month          AS month,
        v.amount         AS amount,
        v.visit_seq      AS visit_seq,
        count(*) OVER (PARTITION BY v.card_number, v.month) AS mvisits
    FROM realt_visits_categorized v
    WHERE toYear(v.month) = toInt32({{year}})
      AND ( {{include_shaa}} = 'Да' OR v.role_group != 'ФОТ ШАА' )
      AND ( {{doctor_type}} = 'Все'
            OR ( {{doctor_type}} = 'Психиатрические' AND v.role_group IN ('ФОТ Психиатры', 'ФОТ ШАА') )
            OR ( {{doctor_type}} = 'Психологические' AND v.role_group = 'ФОТ Психологи' ) )
      AND ( {{doctor_name}} = '' OR v.doctor_name = {{doctor_name}} )
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
      AND ( {{doctor_name}} = '' OR employee_id IN (
            SELECT employee_id FROM realt_employees WHERE full_name = {{doctor_name}}
      ) )
    GROUP BY employee_id
),
-- Накладные (аренда/ФОТ Админов — по этажу; ФОТ Управления+мелкая
-- административка+кредиты/амортизация — общий пул на 2/3 этаж
-- пропорционально их выручке; ШАА не участвует в пуле Управления) и
-- маркетинг (ФОТ Маркетинг+рекламный бюджет+подрядчики+телефония,
-- 80%/20% психиатрия/психология) — та же логика и то же согласование с
-- владельцем 2026-09-19 (второй заход, per-этаж), что и в
-- realt_unitka_by_doctor.sql (см. подробный комментарий там и раздел
-- «Накладные расходы» в docs/formulas/realt.tex). Здесь атрибуция идёт НЕ
-- по одному выбранному врачу, а сразу по каждому employee_id таблицы
-- (группировка по врачу, а не по месяцу).
overhead_payroll AS (
    SELECT
        toMonth(period) AS mnum,
        sumIf(accrued_total, role = 'ФОТ Администраторы' AND department = '2 этаж')                              AS adm_fot_2et,
        sumIf(coalesce(ndfl,0)+coalesce(contributions,0), role = 'ФОТ Администраторы' AND department = '2 этаж') AS adm_taxes_2et,
        sumIf(accrued_total, role = 'ФОТ Администраторы' AND department = '3 этаж')                              AS adm_fot_3et,
        sumIf(coalesce(ndfl,0)+coalesce(contributions,0), role = 'ФОТ Администраторы' AND department = '3 этаж') AS adm_taxes_3et,
        sumIf(accrued_total, role = 'ФОТ Администраторы' AND department = 'ШАА')                                 AS adm_fot_shaa,
        sumIf(coalesce(ndfl,0)+coalesce(contributions,0), role = 'ФОТ Администраторы' AND department = 'ШАА')    AS adm_taxes_shaa,
        sumIf(accrued_total, role = 'ФОТ Управление')                                                            AS upr_fot,
        sumIf(coalesce(ndfl,0)+coalesce(contributions,0), role = 'ФОТ Управление')                               AS upr_taxes,
        sumIf(accrued_total, role = 'ФОТ Маркетинг')                                                             AS mkt_fot,
        sumIf(coalesce(ndfl,0)+coalesce(contributions,0), role = 'ФОТ Маркетинг')                                AS mkt_taxes
    FROM realt_payroll
    WHERE period IS NOT NULL AND toYear(period) = toInt32({{year}})
      AND role IN ('ФОТ Администраторы', 'ФОТ Управление', 'ФОТ Маркетинг')
    GROUP BY mnum
),
clinic_visits AS (
    SELECT
        toMonth(month)                                        AS mnum,
        countIf(role_group IN ('ФОТ Психиатры', 'ФОТ ШАА'))    AS visits_psy,
        countIf(role_group = 'ФОТ Психологи')                  AS visits_pso,
        countIf(visit_floor = '2 этаж')                        AS visits_2et,
        countIf(visit_floor = '3 этаж')                        AS visits_3et,
        countIf(visit_floor = 'ШАА')                           AS visits_shaa,
        sumIf(amount, visit_floor = '2 этаж')                  AS revenue_2et,
        sumIf(amount, visit_floor = '3 этаж')                  AS revenue_3et,
        count()                                                AS visits_total
    FROM realt_visits_categorized
    WHERE toYear(month) = toInt32({{year}})
      AND ( {{include_shaa}} = 'Да' OR role_group != 'ФОТ ШАА' )
    GROUP BY mnum
),
pl_overhead AS (
    -- "Налог на прибыль / УСН" сознательно НЕ включаем — отдельная
    -- формула, владелец согласует позже (см. комментарий выше).
    SELECT
        toMonth(month) AS mnum,
        sumIf(amount, article IN ('Аренда - 2 этаж', 'Ком услуги - 2 этаж', 'Санпэдрежим, охрана труда - 2 этаж')) AS rent_2et,
        sumIf(amount, article IN ('Аренда - 3 этаж', 'Ком услуги - 3 этаж', 'Санпэдрежим, охрана труда - 3 этаж')) AS rent_3et,
        sumIf(amount, article IN ('Аренда - ШАА', 'Ком услуги - ШАА', 'Санпэдрежим, охрана труда - ШАА')) AS rent_shaa,
        sumIf(amount, group_name = 'Административные'
              AND article NOT IN ('ФОТ Управление', 'НДФЛ - Управление', 'Взносы ФОТ - Управление')) AS admin_misc_cost,
        sumIf(amount, article IN ('Проценты по кредитам', 'Амортизация')) AS credit_amort_cost,
        sumIf(amount, group_name = 'Маркетинг'
              AND article IN ('Рекламный бюджет общий', 'Маркетинговые подрядчики', 'Телефония, связь, боты')) AS mkt_pl_cost
    FROM realt_pl_by_group_month
    WHERE toYear(month) = toInt32({{year}})
    GROUP BY mnum
),
overhead_monthly AS (
    SELECT
        cv.mnum AS mnum,
        coalesce(pl.rent_2et, 0)  / nullIf(cv.visits_2et, 0)  AS rent_rate_2et,
        coalesce(pl.rent_3et, 0)  / nullIf(cv.visits_3et, 0)  AS rent_rate_3et,
        coalesce(pl.rent_shaa, 0) / nullIf(cv.visits_shaa, 0) AS rent_rate_shaa,
        ( -coalesce(op.adm_fot_2et, 0) + coalesce(op.adm_taxes_2et, 0) ) / nullIf(cv.visits_2et, 0)    AS adm_rate_2et,
        ( -coalesce(op.adm_fot_3et, 0) + coalesce(op.adm_taxes_3et, 0) ) / nullIf(cv.visits_3et, 0)    AS adm_rate_3et,
        ( -coalesce(op.adm_fot_shaa, 0) + coalesce(op.adm_taxes_shaa, 0) ) / nullIf(cv.visits_shaa, 0) AS adm_rate_shaa,
        (
            ( -coalesce(op.upr_fot, 0) + coalesce(op.upr_taxes, 0) + coalesce(pl.admin_misc_cost, 0) + coalesce(pl.credit_amort_cost, 0) )
            * coalesce(cv.revenue_2et, 0) / nullIf(coalesce(cv.revenue_2et, 0) + coalesce(cv.revenue_3et, 0), 0)
        ) / nullIf(cv.visits_2et, 0) AS upr_rate_2et,
        (
            ( -coalesce(op.upr_fot, 0) + coalesce(op.upr_taxes, 0) + coalesce(pl.admin_misc_cost, 0) + coalesce(pl.credit_amort_cost, 0) )
            * coalesce(cv.revenue_3et, 0) / nullIf(coalesce(cv.revenue_2et, 0) + coalesce(cv.revenue_3et, 0), 0)
        ) / nullIf(cv.visits_3et, 0) AS upr_rate_3et,
        0.8 * ( -coalesce(op.mkt_fot, 0) + coalesce(op.mkt_taxes, 0) + coalesce(pl.mkt_pl_cost, 0) )
            / nullIf(cv.visits_psy, 0) AS mkt_psy_rate,
        0.2 * ( -coalesce(op.mkt_fot, 0) + coalesce(op.mkt_taxes, 0) + coalesce(pl.mkt_pl_cost, 0) )
            / nullIf(cv.visits_pso, 0) AS mkt_pso_rate
    FROM clinic_visits cv
    LEFT JOIN overhead_payroll op ON cv.mnum = op.mnum
    LEFT JOIN pl_overhead pl ON cv.mnum = pl.mnum
),
filtered_overhead AS (
    SELECT
        f.employee_id     AS employee_id,
        toMonth(f.month)  AS mnum,
        multiIf(
            f.visit_floor = '2 этаж', coalesce(om.rent_rate_2et,0) + coalesce(om.adm_rate_2et,0) + coalesce(om.upr_rate_2et,0),
            f.visit_floor = '3 этаж', coalesce(om.rent_rate_3et,0) + coalesce(om.adm_rate_3et,0) + coalesce(om.upr_rate_3et,0),
            f.visit_floor = 'ШАА',    coalesce(om.rent_rate_shaa,0) + coalesce(om.adm_rate_shaa,0),
            0
        ) AS fixed_rate_for_visit,
        multiIf(
            f.role_group IN ('ФОТ Психиатры', 'ФОТ ШАА'), om.mkt_psy_rate,
            f.role_group = 'ФОТ Психологи', om.mkt_pso_rate,
            0
        ) AS mkt_rate_for_visit
    FROM filtered f
    LEFT JOIN overhead_monthly om ON toMonth(f.month) = om.mnum
),
overhead_by_doctor AS (
    SELECT
        employee_id AS employee_id,
        sum(fixed_rate_for_visit) AS fixed_attributed,
        sum(mkt_rate_for_visit)   AS mkt_attributed
    FROM filtered_overhead
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
    toFloat64(r.revenue) - coalesce(toFloat64(f.fot), 0) + coalesce(toFloat64(f.taxes), 0) AS "Прибыль после ФОТ",
    -toFloat64(o.fixed_attributed) / nullIf(toFloat64(if({{unit}} = 'Клиент', r.clients, r.visits)), 0) AS "Накладные на юнит",
    -toFloat64(o.mkt_attributed) / nullIf(toFloat64(if({{unit}} = 'Клиент', r.clients, r.visits)), 0) AS "Маркетинг на юнит",
    toFloat64(r.revenue) - coalesce(toFloat64(f.fot), 0) + coalesce(toFloat64(f.taxes), 0)
        + coalesce(toFloat64(o.fixed_attributed), 0) + coalesce(toFloat64(o.mkt_attributed), 0) AS "Прибыль после всех затрат"
FROM doctor_rev r
FULL OUTER JOIN doctor_fot f ON r.employee_id = f.employee_id
LEFT JOIN (SELECT employee_id, full_name FROM realt_employees FINAL WHERE full_name IS NOT NULL) dn
    ON coalesce(r.employee_id, f.employee_id) = dn.employee_id
LEFT JOIN overhead_by_doctor o ON coalesce(r.employee_id, f.employee_id) = o.employee_id
ORDER BY "Выручка" DESC
-- 2026-09-19: SETTINGS — см. комментарий в realt_unitka_by_doctor.sql
-- (тот же ГОЧТЯ с лимитом оптимизатора ClickHouse на сложных запросах
-- с несколькими CTE и JOIN); здесь UNION ALL нет, но перестраховываемся
-- тем же способом на случай будущего роста числа CTE.
SETTINGS query_plan_max_optimizations_to_apply = 100000
