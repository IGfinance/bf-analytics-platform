-- Metabase: native SQL карточки "Таблица - Реальт - Помесячная юнитка (по
-- врачам, корректная)" (id 183), дашборд id 7.
-- 2026-09-18: добавлен фильтр doctor_name (''=все врачи, как в
-- realt_doctors_table.sql) — раньше карточка всегда агрегировала ВСЮ
-- клинику, выбрать одного врача и увидеть его помесячную динамику было
-- нельзя (см. вики-сессию 2026-09-17, «Следующие шаги»). При выбранном
-- враче строки-разбивки по ролям (ФОТ Психиатры/Психологи/…) станут
-- нулевыми везде, кроме его собственной роли — это ожидаемо, не баг.
-- ГОЧТЯ (подробности в realt_doctors_table.sql): голая строка-комментарий
-- "--" без пробела/текста после ломает разбор параметров в ClickHouse
-- JDBC-драйвере Metabase, даже без единой переменной в самом комментарии
-- ("Похоже, мы получили больше параметров, чем можем обработать"). После
-- "--" всегда должен идти пробел или текст, пустых строк-разделителей нет.
-- То же самое верно для двойных фигурных скобок вокруг имени параметра —
-- движок ищет их и внутри текста комментария тоже, поэтому в этом файле
-- параметры дашборда упоминаются в комментариях простым именем (без
-- скобок) — проверено эмпирически 2026-09-19, та же ошибка "больше
-- параметров, чем можем обработать".
-- 2026-09-19: добавлены строки 23-26 — накладные расходы (ФОТ Админов+
-- Управления+аренда/коммуналка/санпэдрежим+остальной P&L, поровну на
-- визиты клиники) и маркетинг (ФОТ Маркетинг+рекламный бюджет+
-- подрядчики+телефония, 80%/20% психиатрия/психология) — раскладка на
-- визит/клиента даже когда выбран конкретный врач (параметр doctor_name).
-- Решение согласовано с владельцем 2026-09-19 (детали и альтернативы —
-- раздел «Накладные расходы» в docs/formulas/realt.tex). Существующие строки
-- 12-17 (ФОТ Администраторы/Управление/Маркетинг «по роли») НЕ трогали —
-- это другая метрика («ФОТ этой роли у выбранного врача», обоснованно 0
-- для не-администратора), новые строки — отдельная концепция
-- («доля клиники, которую несёт этот срез визитов»).

WITH
base AS (
    SELECT
        v.card_number    AS card_number,
        v.month          AS month,
        v.role_group     AS role_group,
        v.visit_floor    AS visit_floor,
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
monthly_rev AS (
    SELECT
        toMonth(month)                          AS mnum,
        sum(amount)                             AS revenue,
        count()                                 AS visits,
        uniqExact(card_number)                  AS clients,
        uniqExactIf(card_number, visit_seq = 1) AS new_clients
    FROM filtered
    GROUP BY mnum
),
payroll_f AS (
    SELECT
        toMonth(month) AS mnum,
        role_group,
        sumIf(accrued_total, pay_type = 'Проценты')         AS fot_pct,
        sumIf(accrued_total, pay_type IN ('Оклад','Бонус')) AS fot_oklad,
        sum(coalesce(ndfl, 0) + coalesce(contributions, 0)) AS taxes
    FROM realt_payroll_categorized
    WHERE toYear(month) = toInt32({{year}})
      AND ( {{include_shaa}} = 'Да' OR role_group != 'ФОТ ШАА' )
      AND ( {{doctor_type}} = 'Все'
            OR ( {{doctor_type}} = 'Психиатрические' AND role_group IN ('ФОТ Психиатры', 'ФОТ ШАА') )
            OR ( {{doctor_type}} = 'Психологические' AND role_group = 'ФОТ Психологи' )
            -- ГОЧТЯ (найдено и починено 2026-09-19): без этой ветки
            -- Администраторы/Управление/Маркетинг не проходят НИ ОДНО из
            -- условий выше (их role_group не входит ни в психиатрический,
            -- ни в психологический список) — строки 12-17 пивота целиком
            -- пустели при любом doctor_type кроме "Все". doctor_type — это
            -- фильтр по типу ДОКТОРА, эти три роли докторами не являются,
            -- поэтому он их не должен касаться вообще (симметрично тому,
            -- как считаются накладные/маркетинг ниже — там doctor_type
            -- тоже не участвует). Побочный эффект: "ФОТ всего"/"Доля ФОТ в
            -- выручке"/"Прибыль после ФОТ" (fot_total/taxes_total) при
            -- doctor_type != "Все" теперь включают полный ФОТ
            -- Админов+Управления+Маркетинга клиники ПЛЮС отфильтрованный
            -- клинический ФОТ — раньше эти три роли выпадали из fot_total
            -- вместе с остальными
            OR role_group IN ('ФОТ Администраторы', 'ФОТ Управление', 'ФОТ Маркетинг') )
      AND ( {{doctor_name}} = '' OR employee_id IN (
            SELECT employee_id FROM realt_employees WHERE full_name = {{doctor_name}}
      ) )
    GROUP BY mnum, role_group
),
payroll_pivot AS (
    SELECT
        mnum,
        -- fot_total/taxes_total ниже сознательно НЕ включают Админов/
        -- Управление/Маркетинг, когда {{doctor_type}} != "Все" (см. ГОЧТЯ
        -- в payroll_f выше про починку строк 12-17 2026-09-19) — эти три
        -- роли раскладного клиники не являются "типом врача", а fot_total
        -- используется в "ФОТ всего"/"Доля ФОТ в выручке"/"Прибыль после
        -- ФОТ" (строки 6-7/21-22), где ЗНАМЕНАТЕЛЬ (визиты/выручка) тоже
        -- сужен фильтром до одного типа врача. Если сюда добавить полный
        -- клиники-wide накладной ФОТ (как в строках 12-17 после фикса), он
        -- делится на маленький знаменатель одного типа — проверено на
        -- проде 2026-09-19: "Прибыль после ФОТ" на визит для
        -- "Психологические" за год уходит в -8627 ₽ вместо разумного
        -- значения. Поэтому здесь — как было ДО фикса строк 12-17: при
        -- doctor_type="Все" ничего не меняется (все роли и так проходят
        -- payroll_f), при фильтре — накладные роли исключаются из
        -- fot_total/taxes_total тем же способом, что раньше исключались
        -- payroll_f целиком, но строки 12-17 (adm_pct и т.д. ниже) по-
        -- прежнему берут полное клиники-wide значение из payroll_f.
        sum(fot_pct) - if({{doctor_type}} = 'Все', 0,
            coalesce(sumIf(fot_pct, role_group IN ('ФОТ Администраторы', 'ФОТ Управление', 'ФОТ Маркетинг')), 0)
        ) AS fot_total_pct,
        sum(fot_oklad) - if({{doctor_type}} = 'Все', 0,
            coalesce(sumIf(fot_oklad, role_group IN ('ФОТ Администраторы', 'ФОТ Управление', 'ФОТ Маркетинг')), 0)
        ) AS fot_total_oklad,
        sumIf(fot_pct,   role_group = 'ФОТ Психиатры')                  AS psy_pct,
        sumIf(fot_oklad, role_group = 'ФОТ Психиатры')                  AS psy_oklad,
        sumIf(fot_pct,   role_group = 'ФОТ Психологи')                  AS pso_pct,
        sumIf(fot_oklad, role_group = 'ФОТ Психологи')                  AS pso_oklad,
        sumIf(fot_pct,   role_group = 'ФОТ Администраторы')             AS adm_pct,
        sumIf(fot_oklad, role_group = 'ФОТ Администраторы')             AS adm_oklad,
        sumIf(fot_pct,   role_group = 'ФОТ Управление')                 AS upr_pct,
        sumIf(fot_oklad, role_group = 'ФОТ Управление')                 AS upr_oklad,
        sumIf(fot_pct,   role_group = 'ФОТ Маркетинг')                  AS mkt_pct,
        sumIf(fot_oklad, role_group = 'ФОТ Маркетинг')                  AS mkt_oklad,
        sumIf(fot_pct,   role_group = 'ФОТ ШАА')                        AS shaa_pct,
        sumIf(fot_oklad, role_group = 'ФОТ ШАА')                        AS shaa_oklad,
        sum(taxes) - if({{doctor_type}} = 'Все', 0,
            coalesce(sumIf(taxes, role_group IN ('ФОТ Администраторы', 'ФОТ Управление', 'ФОТ Маркетинг')), 0)
        ) AS taxes_total,
        sumIf(taxes, role_group = 'ФОТ Психиатры')                      AS taxes_psy,
        sumIf(taxes, role_group = 'ФОТ Психологи')                      AS taxes_pso,
        sumIf(taxes, role_group = 'ФОТ Администраторы')                 AS taxes_adm,
        sumIf(taxes, role_group = 'ФОТ Управление')                     AS taxes_upr,
        sumIf(taxes, role_group = 'ФОТ Маркетинг')                      AS taxes_mkt,
        sumIf(taxes, role_group = 'ФОТ ШАА')                            AS taxes_shaa
    FROM payroll_f
    GROUP BY mnum
),
-- Накладные расходы и маркетинг — ВСЕГДА считаются по клинике целиком
-- (год/include_shaa), НЕ фильтруются по doctor_name/doctor_type — это
-- сознательно: расходы физически не привязаны к конкретному врачу,
-- поэтому раскладываются на визит по клинике/этажу, а не «зануляются»
-- для врача, который лично не администратор. Согласовано с владельцем
-- 2026-09-19, второй заход (первая версия — плоский общеклинический пул —
-- не сходилась с реальным P&L владельца, см. историю разбора в
-- docs/formulas/realt.tex, раздел «Накладные расходы»):
--   * Аренда/коммуналка/санпэдрежим — СВОЕГО этажа (2 этаж/3 этаж/ШАА,
--     это уже есть в названии статьи), делится на визиты ТОЛЬКО этого
--     этажа — не на всю клинику;
--   * ФОТ Администраторов — тоже по этажу (department сотрудника, свой
--     этаж есть у 2/3/ШАА — проверено на реальных данных: у всех троих
--     есть свои администраторы) — делится на визиты только своего этажа;
--   * ФОТ Управления + «мелкие» административные статьи (Сервисы и
--     подписки, Интернет, Ремонт, Канцелярия, Аутсорс, Мероприятия,
--     Банковские, Прочие админ) + Проценты по кредитам + Амортизация —
--     это уже не по этажам (проверено: department Управления/Маркетинга
--     всегда «УК», управляющая компания), а ЕДИНЫЙ пул, который делится
--     ТОЛЬКО между 2 и 3 этажом пропорционально их выручке — ШАА в нём
--     не участвует вообще (у ШАА, по словам владельца, свои отдельные
--     расходы этого рода, не показанные в этой модели);
--   * «Налог на прибыль / УСН» — ВРЕМЕННО убран из накладных совсем:
--     владелец посчитает отдельно, фиксированным % от выручки или маржи,
--     формула ещё не согласована на 2026-09-19;
--   * Маркетинг (ФОТ Маркетинг+рекламный бюджет+подрядчики+телефония) —
--     БЕЗ изменений, 80% психиатрия (role_group ФОТ Психиатры+ФОТ ШАА) /
--     20% психология (role_group ФОТ Психологи) — это разрез по РОЛИ
--     визита, не по этажу, психотерапевты не выделены отдельно (своего
--     role_group у них нет).
-- Ставка присваивается КАЖДОМУ визиту месяца по его этажу/роли, после
-- чего атрибуция суммируется уже по видимым в текущем фильтре
-- (doctor_name/doctor_type/client_type) визитам.
overhead_payroll AS (
    -- Читаем realt_payroll НАПРЯМУЮ (не realt_payroll_categorized) — та
    -- VIEW подменяет role на "ФОТ ШАА" для строк с department='ШАА', а
    -- здесь нужна ИСХОДНАЯ роль (ФОТ Администраторы и т.д.) именно у
    -- ШАА-сотрудников тоже, плюс сырой department для разбивки по этажу.
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
    -- Визиты/выручка клиники ЦЕЛИКОМ (год + тумблер ШАА) по этажу и по
    -- роли — знаменатели ставок не должны зависеть от того, какой
    -- врач/тип врача сейчас выбран на экране.
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
    -- Источник: realt_pl_by_group_month. Суммы как в исходнике
    -- (отрицательные для расходов). "Налог на прибыль / УСН" сознательно
    -- НЕ включаем (см. комментарий выше — отдельная формула, ещё не
    -- согласована).
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
    -- Ставки НА ОДИН ВИЗИТ своего этажа. Знак — как в «Прибыль после ФОТ»
    -- (revenue - fot + taxes): ФОТ вычитается (негируем), налоги/P&L-
    -- расходы уже отрицательны в источнике — складываем как есть.
    SELECT
        cv.mnum AS mnum,
        coalesce(pl.rent_2et, 0)  / nullIf(cv.visits_2et, 0)  AS rent_rate_2et,
        coalesce(pl.rent_3et, 0)  / nullIf(cv.visits_3et, 0)  AS rent_rate_3et,
        coalesce(pl.rent_shaa, 0) / nullIf(cv.visits_shaa, 0) AS rent_rate_shaa,
        ( -coalesce(op.adm_fot_2et, 0) + coalesce(op.adm_taxes_2et, 0) ) / nullIf(cv.visits_2et, 0)    AS adm_rate_2et,
        ( -coalesce(op.adm_fot_3et, 0) + coalesce(op.adm_taxes_3et, 0) ) / nullIf(cv.visits_3et, 0)    AS adm_rate_3et,
        ( -coalesce(op.adm_fot_shaa, 0) + coalesce(op.adm_taxes_shaa, 0) ) / nullIf(cv.visits_shaa, 0) AS adm_rate_shaa,
        -- Управление + мелкая административка + кредиты/амортизация —
        -- ОДИН пул, делится МЕЖДУ 2 и 3 этажом пропорционально их выручке
        -- (ШАА не участвует вообще — решение владельца 2026-09-19)
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
    -- Атрибуция: каждому визиту из ТЕКУЩЕГО фильтра присваивается ставка
    -- ЕГО этажа (аренда+админы+доля управления) и ЕГО роли (маркетинг).
    -- Сумма по видимым визитам ниже даёт «долю» текущего среза.
    SELECT
        toMonth(f.month) AS mnum,
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
overhead_by_month AS (
    SELECT
        mnum AS mnum,
        sum(fixed_rate_for_visit) AS fixed_attributed,
        sum(mkt_rate_for_visit)   AS mkt_attributed
    FROM filtered_overhead
    GROUP BY mnum
),
monthly AS (
    SELECT
        r.mnum AS mnum,
        r.revenue AS revenue, r.visits AS visits, r.clients AS clients, r.new_clients AS new_clients,
        p.fot_total_pct AS fot_total_pct, p.fot_total_oklad AS fot_total_oklad,
        p.psy_pct AS psy_pct, p.psy_oklad AS psy_oklad,
        p.pso_pct AS pso_pct, p.pso_oklad AS pso_oklad,
        p.adm_pct AS adm_pct, p.adm_oklad AS adm_oklad,
        p.upr_pct AS upr_pct, p.upr_oklad AS upr_oklad,
        p.mkt_pct AS mkt_pct, p.mkt_oklad AS mkt_oklad,
        p.shaa_pct AS shaa_pct, p.shaa_oklad AS shaa_oklad,
        p.taxes_total AS taxes_total,
        p.taxes_psy AS taxes_psy, p.taxes_pso AS taxes_pso, p.taxes_adm AS taxes_adm,
        p.taxes_upr AS taxes_upr, p.taxes_mkt AS taxes_mkt, p.taxes_shaa AS taxes_shaa,
        (coalesce(p.fot_total_pct,0) + coalesce(p.fot_total_oklad,0)) AS fot_total,
        -- fot_own/taxes_own — ТОЛЬКО клинические роли (Психиатры/Психологи/
        -- ШАА), НИКОГДА не включают Админов/Управление/Маркетинг — в
        -- отличие от fot_total (который включает их при doctor_type="Все",
        -- см. ГОЧТЯ у payroll_pivot). Нужны отдельно для строки 26
        -- («Прибыль после ФОТ и накладных»): она уже прибавляет
        -- Админов/Управление через fixed_attributed — использовать там
        -- fot_total означало бы посчитать эти расходы ДВАЖДЫ при
        -- doctor_type="Все" (нашли на проде 2026-09-19: "Прибыль после ФОТ
        -- и накладных" была занижена примерно на величину ФОТ Админов+
        -- Управления+Маркетинга).
        (coalesce(p.psy_pct,0) + coalesce(p.psy_oklad,0)
         + coalesce(p.pso_pct,0) + coalesce(p.pso_oklad,0)
         + coalesce(p.shaa_pct,0) + coalesce(p.shaa_oklad,0)) AS fot_own,
        (coalesce(p.taxes_psy,0) + coalesce(p.taxes_pso,0) + coalesce(p.taxes_shaa,0)) AS taxes_own,
        o.fixed_attributed AS fixed_attributed,
        o.mkt_attributed   AS mkt_attributed,
        -- делитель: клиент или визит, по параметру unit
        if({{unit}} = 'Клиент', r.clients, r.visits) AS denom
    FROM monthly_rev r
    FULL OUTER JOIN payroll_pivot p ON r.mnum = p.mnum
    LEFT JOIN overhead_by_month o ON r.mnum = o.mnum
)
SELECT "Метрика", "Янв","Фев","Мар","Апр","Май","Июн","Июл","Авг","Сен","Окт","Ноя","Дек","За год"
FROM (
SELECT 1 AS rn, 'Выручка на ' || lower({{unit}}) AS "Метрика",
    toFloat64(sumIf(revenue,mnum=1))/nullIf(toFloat64(sumIf(denom,mnum=1)),0) AS "Янв",
    toFloat64(sumIf(revenue,mnum=2))/nullIf(toFloat64(sumIf(denom,mnum=2)),0) AS "Фев",
    toFloat64(sumIf(revenue,mnum=3))/nullIf(toFloat64(sumIf(denom,mnum=3)),0) AS "Мар",
    toFloat64(sumIf(revenue,mnum=4))/nullIf(toFloat64(sumIf(denom,mnum=4)),0) AS "Апр",
    toFloat64(sumIf(revenue,mnum=5))/nullIf(toFloat64(sumIf(denom,mnum=5)),0) AS "Май",
    toFloat64(sumIf(revenue,mnum=6))/nullIf(toFloat64(sumIf(denom,mnum=6)),0) AS "Июн",
    toFloat64(sumIf(revenue,mnum=7))/nullIf(toFloat64(sumIf(denom,mnum=7)),0) AS "Июл",
    toFloat64(sumIf(revenue,mnum=8))/nullIf(toFloat64(sumIf(denom,mnum=8)),0) AS "Авг",
    toFloat64(sumIf(revenue,mnum=9))/nullIf(toFloat64(sumIf(denom,mnum=9)),0) AS "Сен",
    toFloat64(sumIf(revenue,mnum=10))/nullIf(toFloat64(sumIf(denom,mnum=10)),0) AS "Окт",
    toFloat64(sumIf(revenue,mnum=11))/nullIf(toFloat64(sumIf(denom,mnum=11)),0) AS "Ноя",
    toFloat64(sumIf(revenue,mnum=12))/nullIf(toFloat64(sumIf(denom,mnum=12)),0) AS "Дек",
    toFloat64(sum(revenue))/nullIf(toFloat64(sum(denom)),0) AS "За год"
FROM monthly
UNION ALL
SELECT 2, 'Средний чек',
    toFloat64(sumIf(revenue,mnum=1))/nullIf(toFloat64(sumIf(visits,mnum=1)),0),
    toFloat64(sumIf(revenue,mnum=2))/nullIf(toFloat64(sumIf(visits,mnum=2)),0),
    toFloat64(sumIf(revenue,mnum=3))/nullIf(toFloat64(sumIf(visits,mnum=3)),0),
    toFloat64(sumIf(revenue,mnum=4))/nullIf(toFloat64(sumIf(visits,mnum=4)),0),
    toFloat64(sumIf(revenue,mnum=5))/nullIf(toFloat64(sumIf(visits,mnum=5)),0),
    toFloat64(sumIf(revenue,mnum=6))/nullIf(toFloat64(sumIf(visits,mnum=6)),0),
    toFloat64(sumIf(revenue,mnum=7))/nullIf(toFloat64(sumIf(visits,mnum=7)),0),
    toFloat64(sumIf(revenue,mnum=8))/nullIf(toFloat64(sumIf(visits,mnum=8)),0),
    toFloat64(sumIf(revenue,mnum=9))/nullIf(toFloat64(sumIf(visits,mnum=9)),0),
    toFloat64(sumIf(revenue,mnum=10))/nullIf(toFloat64(sumIf(visits,mnum=10)),0),
    toFloat64(sumIf(revenue,mnum=11))/nullIf(toFloat64(sumIf(visits,mnum=11)),0),
    toFloat64(sumIf(revenue,mnum=12))/nullIf(toFloat64(sumIf(visits,mnum=12)),0),
    toFloat64(sum(revenue))/nullIf(toFloat64(sum(visits)),0)
FROM monthly
UNION ALL
SELECT 3, 'Визиты',
    toFloat64(sumIf(visits,mnum=1)),
    toFloat64(sumIf(visits,mnum=2)),
    toFloat64(sumIf(visits,mnum=3)),
    toFloat64(sumIf(visits,mnum=4)),
    toFloat64(sumIf(visits,mnum=5)),
    toFloat64(sumIf(visits,mnum=6)),
    toFloat64(sumIf(visits,mnum=7)),
    toFloat64(sumIf(visits,mnum=8)),
    toFloat64(sumIf(visits,mnum=9)),
    toFloat64(sumIf(visits,mnum=10)),
    toFloat64(sumIf(visits,mnum=11)),
    toFloat64(sumIf(visits,mnum=12)),
    toFloat64(sum(visits))
FROM monthly
UNION ALL
SELECT 4, 'Клиенты',
    toFloat64(sumIf(clients,mnum=1)),
    toFloat64(sumIf(clients,mnum=2)),
    toFloat64(sumIf(clients,mnum=3)),
    toFloat64(sumIf(clients,mnum=4)),
    toFloat64(sumIf(clients,mnum=5)),
    toFloat64(sumIf(clients,mnum=6)),
    toFloat64(sumIf(clients,mnum=7)),
    toFloat64(sumIf(clients,mnum=8)),
    toFloat64(sumIf(clients,mnum=9)),
    toFloat64(sumIf(clients,mnum=10)),
    toFloat64(sumIf(clients,mnum=11)),
    toFloat64(sumIf(clients,mnum=12)),
    toFloat64(sum(clients))
FROM monthly
UNION ALL
SELECT 5, 'Новые клиенты',
    toFloat64(sumIf(new_clients,mnum=1)),
    toFloat64(sumIf(new_clients,mnum=2)),
    toFloat64(sumIf(new_clients,mnum=3)),
    toFloat64(sumIf(new_clients,mnum=4)),
    toFloat64(sumIf(new_clients,mnum=5)),
    toFloat64(sumIf(new_clients,mnum=6)),
    toFloat64(sumIf(new_clients,mnum=7)),
    toFloat64(sumIf(new_clients,mnum=8)),
    toFloat64(sumIf(new_clients,mnum=9)),
    toFloat64(sumIf(new_clients,mnum=10)),
    toFloat64(sumIf(new_clients,mnum=11)),
    toFloat64(sumIf(new_clients,mnum=12)),
    toFloat64(sum(new_clients))
FROM monthly
UNION ALL
SELECT 6, 'ФОТ всего — Проценты на ' || lower({{unit}}),
    toFloat64(sumIf(fot_total_pct,mnum=1))/nullIf(toFloat64(sumIf(denom,mnum=1)),0),
    toFloat64(sumIf(fot_total_pct,mnum=2))/nullIf(toFloat64(sumIf(denom,mnum=2)),0),
    toFloat64(sumIf(fot_total_pct,mnum=3))/nullIf(toFloat64(sumIf(denom,mnum=3)),0),
    toFloat64(sumIf(fot_total_pct,mnum=4))/nullIf(toFloat64(sumIf(denom,mnum=4)),0),
    toFloat64(sumIf(fot_total_pct,mnum=5))/nullIf(toFloat64(sumIf(denom,mnum=5)),0),
    toFloat64(sumIf(fot_total_pct,mnum=6))/nullIf(toFloat64(sumIf(denom,mnum=6)),0),
    toFloat64(sumIf(fot_total_pct,mnum=7))/nullIf(toFloat64(sumIf(denom,mnum=7)),0),
    toFloat64(sumIf(fot_total_pct,mnum=8))/nullIf(toFloat64(sumIf(denom,mnum=8)),0),
    toFloat64(sumIf(fot_total_pct,mnum=9))/nullIf(toFloat64(sumIf(denom,mnum=9)),0),
    toFloat64(sumIf(fot_total_pct,mnum=10))/nullIf(toFloat64(sumIf(denom,mnum=10)),0),
    toFloat64(sumIf(fot_total_pct,mnum=11))/nullIf(toFloat64(sumIf(denom,mnum=11)),0),
    toFloat64(sumIf(fot_total_pct,mnum=12))/nullIf(toFloat64(sumIf(denom,mnum=12)),0),
    toFloat64(sum(fot_total_pct))/nullIf(toFloat64(sum(denom)),0)
FROM monthly
UNION ALL
SELECT 7, 'ФОТ всего — Оклад+Бонус на ' || lower({{unit}}),
    toFloat64(sumIf(fot_total_oklad,mnum=1))/nullIf(toFloat64(sumIf(denom,mnum=1)),0),
    toFloat64(sumIf(fot_total_oklad,mnum=2))/nullIf(toFloat64(sumIf(denom,mnum=2)),0),
    toFloat64(sumIf(fot_total_oklad,mnum=3))/nullIf(toFloat64(sumIf(denom,mnum=3)),0),
    toFloat64(sumIf(fot_total_oklad,mnum=4))/nullIf(toFloat64(sumIf(denom,mnum=4)),0),
    toFloat64(sumIf(fot_total_oklad,mnum=5))/nullIf(toFloat64(sumIf(denom,mnum=5)),0),
    toFloat64(sumIf(fot_total_oklad,mnum=6))/nullIf(toFloat64(sumIf(denom,mnum=6)),0),
    toFloat64(sumIf(fot_total_oklad,mnum=7))/nullIf(toFloat64(sumIf(denom,mnum=7)),0),
    toFloat64(sumIf(fot_total_oklad,mnum=8))/nullIf(toFloat64(sumIf(denom,mnum=8)),0),
    toFloat64(sumIf(fot_total_oklad,mnum=9))/nullIf(toFloat64(sumIf(denom,mnum=9)),0),
    toFloat64(sumIf(fot_total_oklad,mnum=10))/nullIf(toFloat64(sumIf(denom,mnum=10)),0),
    toFloat64(sumIf(fot_total_oklad,mnum=11))/nullIf(toFloat64(sumIf(denom,mnum=11)),0),
    toFloat64(sumIf(fot_total_oklad,mnum=12))/nullIf(toFloat64(sumIf(denom,mnum=12)),0),
    toFloat64(sum(fot_total_oklad))/nullIf(toFloat64(sum(denom)),0)
FROM monthly
UNION ALL
SELECT 8, 'ФОТ Психиатры — Проценты на ' || lower({{unit}}),
    toFloat64(sumIf(psy_pct,mnum=1))/nullIf(toFloat64(sumIf(denom,mnum=1)),0),
    toFloat64(sumIf(psy_pct,mnum=2))/nullIf(toFloat64(sumIf(denom,mnum=2)),0),
    toFloat64(sumIf(psy_pct,mnum=3))/nullIf(toFloat64(sumIf(denom,mnum=3)),0),
    toFloat64(sumIf(psy_pct,mnum=4))/nullIf(toFloat64(sumIf(denom,mnum=4)),0),
    toFloat64(sumIf(psy_pct,mnum=5))/nullIf(toFloat64(sumIf(denom,mnum=5)),0),
    toFloat64(sumIf(psy_pct,mnum=6))/nullIf(toFloat64(sumIf(denom,mnum=6)),0),
    toFloat64(sumIf(psy_pct,mnum=7))/nullIf(toFloat64(sumIf(denom,mnum=7)),0),
    toFloat64(sumIf(psy_pct,mnum=8))/nullIf(toFloat64(sumIf(denom,mnum=8)),0),
    toFloat64(sumIf(psy_pct,mnum=9))/nullIf(toFloat64(sumIf(denom,mnum=9)),0),
    toFloat64(sumIf(psy_pct,mnum=10))/nullIf(toFloat64(sumIf(denom,mnum=10)),0),
    toFloat64(sumIf(psy_pct,mnum=11))/nullIf(toFloat64(sumIf(denom,mnum=11)),0),
    toFloat64(sumIf(psy_pct,mnum=12))/nullIf(toFloat64(sumIf(denom,mnum=12)),0),
    toFloat64(sum(psy_pct))/nullIf(toFloat64(sum(denom)),0)
FROM monthly
UNION ALL
SELECT 9, 'ФОТ Психиатры — Оклад+Бонус на ' || lower({{unit}}),
    toFloat64(sumIf(psy_oklad,mnum=1))/nullIf(toFloat64(sumIf(denom,mnum=1)),0),
    toFloat64(sumIf(psy_oklad,mnum=2))/nullIf(toFloat64(sumIf(denom,mnum=2)),0),
    toFloat64(sumIf(psy_oklad,mnum=3))/nullIf(toFloat64(sumIf(denom,mnum=3)),0),
    toFloat64(sumIf(psy_oklad,mnum=4))/nullIf(toFloat64(sumIf(denom,mnum=4)),0),
    toFloat64(sumIf(psy_oklad,mnum=5))/nullIf(toFloat64(sumIf(denom,mnum=5)),0),
    toFloat64(sumIf(psy_oklad,mnum=6))/nullIf(toFloat64(sumIf(denom,mnum=6)),0),
    toFloat64(sumIf(psy_oklad,mnum=7))/nullIf(toFloat64(sumIf(denom,mnum=7)),0),
    toFloat64(sumIf(psy_oklad,mnum=8))/nullIf(toFloat64(sumIf(denom,mnum=8)),0),
    toFloat64(sumIf(psy_oklad,mnum=9))/nullIf(toFloat64(sumIf(denom,mnum=9)),0),
    toFloat64(sumIf(psy_oklad,mnum=10))/nullIf(toFloat64(sumIf(denom,mnum=10)),0),
    toFloat64(sumIf(psy_oklad,mnum=11))/nullIf(toFloat64(sumIf(denom,mnum=11)),0),
    toFloat64(sumIf(psy_oklad,mnum=12))/nullIf(toFloat64(sumIf(denom,mnum=12)),0),
    toFloat64(sum(psy_oklad))/nullIf(toFloat64(sum(denom)),0)
FROM monthly
UNION ALL
SELECT 10, 'ФОТ Психологи — Проценты на ' || lower({{unit}}),
    toFloat64(sumIf(pso_pct,mnum=1))/nullIf(toFloat64(sumIf(denom,mnum=1)),0),
    toFloat64(sumIf(pso_pct,mnum=2))/nullIf(toFloat64(sumIf(denom,mnum=2)),0),
    toFloat64(sumIf(pso_pct,mnum=3))/nullIf(toFloat64(sumIf(denom,mnum=3)),0),
    toFloat64(sumIf(pso_pct,mnum=4))/nullIf(toFloat64(sumIf(denom,mnum=4)),0),
    toFloat64(sumIf(pso_pct,mnum=5))/nullIf(toFloat64(sumIf(denom,mnum=5)),0),
    toFloat64(sumIf(pso_pct,mnum=6))/nullIf(toFloat64(sumIf(denom,mnum=6)),0),
    toFloat64(sumIf(pso_pct,mnum=7))/nullIf(toFloat64(sumIf(denom,mnum=7)),0),
    toFloat64(sumIf(pso_pct,mnum=8))/nullIf(toFloat64(sumIf(denom,mnum=8)),0),
    toFloat64(sumIf(pso_pct,mnum=9))/nullIf(toFloat64(sumIf(denom,mnum=9)),0),
    toFloat64(sumIf(pso_pct,mnum=10))/nullIf(toFloat64(sumIf(denom,mnum=10)),0),
    toFloat64(sumIf(pso_pct,mnum=11))/nullIf(toFloat64(sumIf(denom,mnum=11)),0),
    toFloat64(sumIf(pso_pct,mnum=12))/nullIf(toFloat64(sumIf(denom,mnum=12)),0),
    toFloat64(sum(pso_pct))/nullIf(toFloat64(sum(denom)),0)
FROM monthly
UNION ALL
SELECT 11, 'ФОТ Психологи — Оклад+Бонус на ' || lower({{unit}}),
    toFloat64(sumIf(pso_oklad,mnum=1))/nullIf(toFloat64(sumIf(denom,mnum=1)),0),
    toFloat64(sumIf(pso_oklad,mnum=2))/nullIf(toFloat64(sumIf(denom,mnum=2)),0),
    toFloat64(sumIf(pso_oklad,mnum=3))/nullIf(toFloat64(sumIf(denom,mnum=3)),0),
    toFloat64(sumIf(pso_oklad,mnum=4))/nullIf(toFloat64(sumIf(denom,mnum=4)),0),
    toFloat64(sumIf(pso_oklad,mnum=5))/nullIf(toFloat64(sumIf(denom,mnum=5)),0),
    toFloat64(sumIf(pso_oklad,mnum=6))/nullIf(toFloat64(sumIf(denom,mnum=6)),0),
    toFloat64(sumIf(pso_oklad,mnum=7))/nullIf(toFloat64(sumIf(denom,mnum=7)),0),
    toFloat64(sumIf(pso_oklad,mnum=8))/nullIf(toFloat64(sumIf(denom,mnum=8)),0),
    toFloat64(sumIf(pso_oklad,mnum=9))/nullIf(toFloat64(sumIf(denom,mnum=9)),0),
    toFloat64(sumIf(pso_oklad,mnum=10))/nullIf(toFloat64(sumIf(denom,mnum=10)),0),
    toFloat64(sumIf(pso_oklad,mnum=11))/nullIf(toFloat64(sumIf(denom,mnum=11)),0),
    toFloat64(sumIf(pso_oklad,mnum=12))/nullIf(toFloat64(sumIf(denom,mnum=12)),0),
    toFloat64(sum(pso_oklad))/nullIf(toFloat64(sum(denom)),0)
FROM monthly
UNION ALL
SELECT 12, 'ФОТ Администраторы — Проценты на ' || lower({{unit}}),
    toFloat64(sumIf(adm_pct,mnum=1))/nullIf(toFloat64(sumIf(denom,mnum=1)),0),
    toFloat64(sumIf(adm_pct,mnum=2))/nullIf(toFloat64(sumIf(denom,mnum=2)),0),
    toFloat64(sumIf(adm_pct,mnum=3))/nullIf(toFloat64(sumIf(denom,mnum=3)),0),
    toFloat64(sumIf(adm_pct,mnum=4))/nullIf(toFloat64(sumIf(denom,mnum=4)),0),
    toFloat64(sumIf(adm_pct,mnum=5))/nullIf(toFloat64(sumIf(denom,mnum=5)),0),
    toFloat64(sumIf(adm_pct,mnum=6))/nullIf(toFloat64(sumIf(denom,mnum=6)),0),
    toFloat64(sumIf(adm_pct,mnum=7))/nullIf(toFloat64(sumIf(denom,mnum=7)),0),
    toFloat64(sumIf(adm_pct,mnum=8))/nullIf(toFloat64(sumIf(denom,mnum=8)),0),
    toFloat64(sumIf(adm_pct,mnum=9))/nullIf(toFloat64(sumIf(denom,mnum=9)),0),
    toFloat64(sumIf(adm_pct,mnum=10))/nullIf(toFloat64(sumIf(denom,mnum=10)),0),
    toFloat64(sumIf(adm_pct,mnum=11))/nullIf(toFloat64(sumIf(denom,mnum=11)),0),
    toFloat64(sumIf(adm_pct,mnum=12))/nullIf(toFloat64(sumIf(denom,mnum=12)),0),
    toFloat64(sum(adm_pct))/nullIf(toFloat64(sum(denom)),0)
FROM monthly
UNION ALL
SELECT 13, 'ФОТ Администраторы — Оклад+Бонус на ' || lower({{unit}}),
    toFloat64(sumIf(adm_oklad,mnum=1))/nullIf(toFloat64(sumIf(denom,mnum=1)),0),
    toFloat64(sumIf(adm_oklad,mnum=2))/nullIf(toFloat64(sumIf(denom,mnum=2)),0),
    toFloat64(sumIf(adm_oklad,mnum=3))/nullIf(toFloat64(sumIf(denom,mnum=3)),0),
    toFloat64(sumIf(adm_oklad,mnum=4))/nullIf(toFloat64(sumIf(denom,mnum=4)),0),
    toFloat64(sumIf(adm_oklad,mnum=5))/nullIf(toFloat64(sumIf(denom,mnum=5)),0),
    toFloat64(sumIf(adm_oklad,mnum=6))/nullIf(toFloat64(sumIf(denom,mnum=6)),0),
    toFloat64(sumIf(adm_oklad,mnum=7))/nullIf(toFloat64(sumIf(denom,mnum=7)),0),
    toFloat64(sumIf(adm_oklad,mnum=8))/nullIf(toFloat64(sumIf(denom,mnum=8)),0),
    toFloat64(sumIf(adm_oklad,mnum=9))/nullIf(toFloat64(sumIf(denom,mnum=9)),0),
    toFloat64(sumIf(adm_oklad,mnum=10))/nullIf(toFloat64(sumIf(denom,mnum=10)),0),
    toFloat64(sumIf(adm_oklad,mnum=11))/nullIf(toFloat64(sumIf(denom,mnum=11)),0),
    toFloat64(sumIf(adm_oklad,mnum=12))/nullIf(toFloat64(sumIf(denom,mnum=12)),0),
    toFloat64(sum(adm_oklad))/nullIf(toFloat64(sum(denom)),0)
FROM monthly
UNION ALL
SELECT 14, 'ФОТ Управление — Проценты на ' || lower({{unit}}),
    toFloat64(sumIf(upr_pct,mnum=1))/nullIf(toFloat64(sumIf(denom,mnum=1)),0),
    toFloat64(sumIf(upr_pct,mnum=2))/nullIf(toFloat64(sumIf(denom,mnum=2)),0),
    toFloat64(sumIf(upr_pct,mnum=3))/nullIf(toFloat64(sumIf(denom,mnum=3)),0),
    toFloat64(sumIf(upr_pct,mnum=4))/nullIf(toFloat64(sumIf(denom,mnum=4)),0),
    toFloat64(sumIf(upr_pct,mnum=5))/nullIf(toFloat64(sumIf(denom,mnum=5)),0),
    toFloat64(sumIf(upr_pct,mnum=6))/nullIf(toFloat64(sumIf(denom,mnum=6)),0),
    toFloat64(sumIf(upr_pct,mnum=7))/nullIf(toFloat64(sumIf(denom,mnum=7)),0),
    toFloat64(sumIf(upr_pct,mnum=8))/nullIf(toFloat64(sumIf(denom,mnum=8)),0),
    toFloat64(sumIf(upr_pct,mnum=9))/nullIf(toFloat64(sumIf(denom,mnum=9)),0),
    toFloat64(sumIf(upr_pct,mnum=10))/nullIf(toFloat64(sumIf(denom,mnum=10)),0),
    toFloat64(sumIf(upr_pct,mnum=11))/nullIf(toFloat64(sumIf(denom,mnum=11)),0),
    toFloat64(sumIf(upr_pct,mnum=12))/nullIf(toFloat64(sumIf(denom,mnum=12)),0),
    toFloat64(sum(upr_pct))/nullIf(toFloat64(sum(denom)),0)
FROM monthly
UNION ALL
SELECT 15, 'ФОТ Управление — Оклад+Бонус на ' || lower({{unit}}),
    toFloat64(sumIf(upr_oklad,mnum=1))/nullIf(toFloat64(sumIf(denom,mnum=1)),0),
    toFloat64(sumIf(upr_oklad,mnum=2))/nullIf(toFloat64(sumIf(denom,mnum=2)),0),
    toFloat64(sumIf(upr_oklad,mnum=3))/nullIf(toFloat64(sumIf(denom,mnum=3)),0),
    toFloat64(sumIf(upr_oklad,mnum=4))/nullIf(toFloat64(sumIf(denom,mnum=4)),0),
    toFloat64(sumIf(upr_oklad,mnum=5))/nullIf(toFloat64(sumIf(denom,mnum=5)),0),
    toFloat64(sumIf(upr_oklad,mnum=6))/nullIf(toFloat64(sumIf(denom,mnum=6)),0),
    toFloat64(sumIf(upr_oklad,mnum=7))/nullIf(toFloat64(sumIf(denom,mnum=7)),0),
    toFloat64(sumIf(upr_oklad,mnum=8))/nullIf(toFloat64(sumIf(denom,mnum=8)),0),
    toFloat64(sumIf(upr_oklad,mnum=9))/nullIf(toFloat64(sumIf(denom,mnum=9)),0),
    toFloat64(sumIf(upr_oklad,mnum=10))/nullIf(toFloat64(sumIf(denom,mnum=10)),0),
    toFloat64(sumIf(upr_oklad,mnum=11))/nullIf(toFloat64(sumIf(denom,mnum=11)),0),
    toFloat64(sumIf(upr_oklad,mnum=12))/nullIf(toFloat64(sumIf(denom,mnum=12)),0),
    toFloat64(sum(upr_oklad))/nullIf(toFloat64(sum(denom)),0)
FROM monthly
UNION ALL
SELECT 16, 'ФОТ Маркетинг — Проценты на ' || lower({{unit}}),
    toFloat64(sumIf(mkt_pct,mnum=1))/nullIf(toFloat64(sumIf(denom,mnum=1)),0),
    toFloat64(sumIf(mkt_pct,mnum=2))/nullIf(toFloat64(sumIf(denom,mnum=2)),0),
    toFloat64(sumIf(mkt_pct,mnum=3))/nullIf(toFloat64(sumIf(denom,mnum=3)),0),
    toFloat64(sumIf(mkt_pct,mnum=4))/nullIf(toFloat64(sumIf(denom,mnum=4)),0),
    toFloat64(sumIf(mkt_pct,mnum=5))/nullIf(toFloat64(sumIf(denom,mnum=5)),0),
    toFloat64(sumIf(mkt_pct,mnum=6))/nullIf(toFloat64(sumIf(denom,mnum=6)),0),
    toFloat64(sumIf(mkt_pct,mnum=7))/nullIf(toFloat64(sumIf(denom,mnum=7)),0),
    toFloat64(sumIf(mkt_pct,mnum=8))/nullIf(toFloat64(sumIf(denom,mnum=8)),0),
    toFloat64(sumIf(mkt_pct,mnum=9))/nullIf(toFloat64(sumIf(denom,mnum=9)),0),
    toFloat64(sumIf(mkt_pct,mnum=10))/nullIf(toFloat64(sumIf(denom,mnum=10)),0),
    toFloat64(sumIf(mkt_pct,mnum=11))/nullIf(toFloat64(sumIf(denom,mnum=11)),0),
    toFloat64(sumIf(mkt_pct,mnum=12))/nullIf(toFloat64(sumIf(denom,mnum=12)),0),
    toFloat64(sum(mkt_pct))/nullIf(toFloat64(sum(denom)),0)
FROM monthly
UNION ALL
SELECT 17, 'ФОТ Маркетинг — Оклад+Бонус на ' || lower({{unit}}),
    toFloat64(sumIf(mkt_oklad,mnum=1))/nullIf(toFloat64(sumIf(denom,mnum=1)),0),
    toFloat64(sumIf(mkt_oklad,mnum=2))/nullIf(toFloat64(sumIf(denom,mnum=2)),0),
    toFloat64(sumIf(mkt_oklad,mnum=3))/nullIf(toFloat64(sumIf(denom,mnum=3)),0),
    toFloat64(sumIf(mkt_oklad,mnum=4))/nullIf(toFloat64(sumIf(denom,mnum=4)),0),
    toFloat64(sumIf(mkt_oklad,mnum=5))/nullIf(toFloat64(sumIf(denom,mnum=5)),0),
    toFloat64(sumIf(mkt_oklad,mnum=6))/nullIf(toFloat64(sumIf(denom,mnum=6)),0),
    toFloat64(sumIf(mkt_oklad,mnum=7))/nullIf(toFloat64(sumIf(denom,mnum=7)),0),
    toFloat64(sumIf(mkt_oklad,mnum=8))/nullIf(toFloat64(sumIf(denom,mnum=8)),0),
    toFloat64(sumIf(mkt_oklad,mnum=9))/nullIf(toFloat64(sumIf(denom,mnum=9)),0),
    toFloat64(sumIf(mkt_oklad,mnum=10))/nullIf(toFloat64(sumIf(denom,mnum=10)),0),
    toFloat64(sumIf(mkt_oklad,mnum=11))/nullIf(toFloat64(sumIf(denom,mnum=11)),0),
    toFloat64(sumIf(mkt_oklad,mnum=12))/nullIf(toFloat64(sumIf(denom,mnum=12)),0),
    toFloat64(sum(mkt_oklad))/nullIf(toFloat64(sum(denom)),0)
FROM monthly
UNION ALL
SELECT 18, 'ФОТ ШАА — Проценты на ' || lower({{unit}}),
    toFloat64(sumIf(shaa_pct,mnum=1))/nullIf(toFloat64(sumIf(denom,mnum=1)),0),
    toFloat64(sumIf(shaa_pct,mnum=2))/nullIf(toFloat64(sumIf(denom,mnum=2)),0),
    toFloat64(sumIf(shaa_pct,mnum=3))/nullIf(toFloat64(sumIf(denom,mnum=3)),0),
    toFloat64(sumIf(shaa_pct,mnum=4))/nullIf(toFloat64(sumIf(denom,mnum=4)),0),
    toFloat64(sumIf(shaa_pct,mnum=5))/nullIf(toFloat64(sumIf(denom,mnum=5)),0),
    toFloat64(sumIf(shaa_pct,mnum=6))/nullIf(toFloat64(sumIf(denom,mnum=6)),0),
    toFloat64(sumIf(shaa_pct,mnum=7))/nullIf(toFloat64(sumIf(denom,mnum=7)),0),
    toFloat64(sumIf(shaa_pct,mnum=8))/nullIf(toFloat64(sumIf(denom,mnum=8)),0),
    toFloat64(sumIf(shaa_pct,mnum=9))/nullIf(toFloat64(sumIf(denom,mnum=9)),0),
    toFloat64(sumIf(shaa_pct,mnum=10))/nullIf(toFloat64(sumIf(denom,mnum=10)),0),
    toFloat64(sumIf(shaa_pct,mnum=11))/nullIf(toFloat64(sumIf(denom,mnum=11)),0),
    toFloat64(sumIf(shaa_pct,mnum=12))/nullIf(toFloat64(sumIf(denom,mnum=12)),0),
    toFloat64(sum(shaa_pct))/nullIf(toFloat64(sum(denom)),0)
FROM monthly
UNION ALL
SELECT 19, 'ФОТ ШАА — Оклад+Бонус на ' || lower({{unit}}),
    toFloat64(sumIf(shaa_oklad,mnum=1))/nullIf(toFloat64(sumIf(denom,mnum=1)),0),
    toFloat64(sumIf(shaa_oklad,mnum=2))/nullIf(toFloat64(sumIf(denom,mnum=2)),0),
    toFloat64(sumIf(shaa_oklad,mnum=3))/nullIf(toFloat64(sumIf(denom,mnum=3)),0),
    toFloat64(sumIf(shaa_oklad,mnum=4))/nullIf(toFloat64(sumIf(denom,mnum=4)),0),
    toFloat64(sumIf(shaa_oklad,mnum=5))/nullIf(toFloat64(sumIf(denom,mnum=5)),0),
    toFloat64(sumIf(shaa_oklad,mnum=6))/nullIf(toFloat64(sumIf(denom,mnum=6)),0),
    toFloat64(sumIf(shaa_oklad,mnum=7))/nullIf(toFloat64(sumIf(denom,mnum=7)),0),
    toFloat64(sumIf(shaa_oklad,mnum=8))/nullIf(toFloat64(sumIf(denom,mnum=8)),0),
    toFloat64(sumIf(shaa_oklad,mnum=9))/nullIf(toFloat64(sumIf(denom,mnum=9)),0),
    toFloat64(sumIf(shaa_oklad,mnum=10))/nullIf(toFloat64(sumIf(denom,mnum=10)),0),
    toFloat64(sumIf(shaa_oklad,mnum=11))/nullIf(toFloat64(sumIf(denom,mnum=11)),0),
    toFloat64(sumIf(shaa_oklad,mnum=12))/nullIf(toFloat64(sumIf(denom,mnum=12)),0),
    toFloat64(sum(shaa_oklad))/nullIf(toFloat64(sum(denom)),0)
FROM monthly
UNION ALL
SELECT 20, 'Налоги и взносы с ФОТ на ' || lower({{unit}}),
    toFloat64(sumIf(taxes_total,mnum=1))/nullIf(toFloat64(sumIf(denom,mnum=1)),0),
    toFloat64(sumIf(taxes_total,mnum=2))/nullIf(toFloat64(sumIf(denom,mnum=2)),0),
    toFloat64(sumIf(taxes_total,mnum=3))/nullIf(toFloat64(sumIf(denom,mnum=3)),0),
    toFloat64(sumIf(taxes_total,mnum=4))/nullIf(toFloat64(sumIf(denom,mnum=4)),0),
    toFloat64(sumIf(taxes_total,mnum=5))/nullIf(toFloat64(sumIf(denom,mnum=5)),0),
    toFloat64(sumIf(taxes_total,mnum=6))/nullIf(toFloat64(sumIf(denom,mnum=6)),0),
    toFloat64(sumIf(taxes_total,mnum=7))/nullIf(toFloat64(sumIf(denom,mnum=7)),0),
    toFloat64(sumIf(taxes_total,mnum=8))/nullIf(toFloat64(sumIf(denom,mnum=8)),0),
    toFloat64(sumIf(taxes_total,mnum=9))/nullIf(toFloat64(sumIf(denom,mnum=9)),0),
    toFloat64(sumIf(taxes_total,mnum=10))/nullIf(toFloat64(sumIf(denom,mnum=10)),0),
    toFloat64(sumIf(taxes_total,mnum=11))/nullIf(toFloat64(sumIf(denom,mnum=11)),0),
    toFloat64(sumIf(taxes_total,mnum=12))/nullIf(toFloat64(sumIf(denom,mnum=12)),0),
    toFloat64(sum(taxes_total))/nullIf(toFloat64(sum(denom)),0)
FROM monthly
UNION ALL
SELECT 21, 'Доля ФОТ в выручке, %',
    toFloat64(sumIf(fot_total,mnum=1))/nullIf(toFloat64(sumIf(revenue,mnum=1)),0)*100,
    toFloat64(sumIf(fot_total,mnum=2))/nullIf(toFloat64(sumIf(revenue,mnum=2)),0)*100,
    toFloat64(sumIf(fot_total,mnum=3))/nullIf(toFloat64(sumIf(revenue,mnum=3)),0)*100,
    toFloat64(sumIf(fot_total,mnum=4))/nullIf(toFloat64(sumIf(revenue,mnum=4)),0)*100,
    toFloat64(sumIf(fot_total,mnum=5))/nullIf(toFloat64(sumIf(revenue,mnum=5)),0)*100,
    toFloat64(sumIf(fot_total,mnum=6))/nullIf(toFloat64(sumIf(revenue,mnum=6)),0)*100,
    toFloat64(sumIf(fot_total,mnum=7))/nullIf(toFloat64(sumIf(revenue,mnum=7)),0)*100,
    toFloat64(sumIf(fot_total,mnum=8))/nullIf(toFloat64(sumIf(revenue,mnum=8)),0)*100,
    toFloat64(sumIf(fot_total,mnum=9))/nullIf(toFloat64(sumIf(revenue,mnum=9)),0)*100,
    toFloat64(sumIf(fot_total,mnum=10))/nullIf(toFloat64(sumIf(revenue,mnum=10)),0)*100,
    toFloat64(sumIf(fot_total,mnum=11))/nullIf(toFloat64(sumIf(revenue,mnum=11)),0)*100,
    toFloat64(sumIf(fot_total,mnum=12))/nullIf(toFloat64(sumIf(revenue,mnum=12)),0)*100,
    toFloat64(sum(fot_total))/nullIf(toFloat64(sum(revenue)),0)*100
FROM monthly
UNION ALL
SELECT 22, 'Прибыль после ФОТ на ' || lower({{unit}}),
    (toFloat64(sumIf(revenue,mnum=1))-coalesce(toFloat64(sumIf(fot_total,mnum=1)),0)+coalesce(toFloat64(sumIf(taxes_total,mnum=1)),0))/nullIf(toFloat64(sumIf(denom,mnum=1)),0),
    (toFloat64(sumIf(revenue,mnum=2))-coalesce(toFloat64(sumIf(fot_total,mnum=2)),0)+coalesce(toFloat64(sumIf(taxes_total,mnum=2)),0))/nullIf(toFloat64(sumIf(denom,mnum=2)),0),
    (toFloat64(sumIf(revenue,mnum=3))-coalesce(toFloat64(sumIf(fot_total,mnum=3)),0)+coalesce(toFloat64(sumIf(taxes_total,mnum=3)),0))/nullIf(toFloat64(sumIf(denom,mnum=3)),0),
    (toFloat64(sumIf(revenue,mnum=4))-coalesce(toFloat64(sumIf(fot_total,mnum=4)),0)+coalesce(toFloat64(sumIf(taxes_total,mnum=4)),0))/nullIf(toFloat64(sumIf(denom,mnum=4)),0),
    (toFloat64(sumIf(revenue,mnum=5))-coalesce(toFloat64(sumIf(fot_total,mnum=5)),0)+coalesce(toFloat64(sumIf(taxes_total,mnum=5)),0))/nullIf(toFloat64(sumIf(denom,mnum=5)),0),
    (toFloat64(sumIf(revenue,mnum=6))-coalesce(toFloat64(sumIf(fot_total,mnum=6)),0)+coalesce(toFloat64(sumIf(taxes_total,mnum=6)),0))/nullIf(toFloat64(sumIf(denom,mnum=6)),0),
    (toFloat64(sumIf(revenue,mnum=7))-coalesce(toFloat64(sumIf(fot_total,mnum=7)),0)+coalesce(toFloat64(sumIf(taxes_total,mnum=7)),0))/nullIf(toFloat64(sumIf(denom,mnum=7)),0),
    (toFloat64(sumIf(revenue,mnum=8))-coalesce(toFloat64(sumIf(fot_total,mnum=8)),0)+coalesce(toFloat64(sumIf(taxes_total,mnum=8)),0))/nullIf(toFloat64(sumIf(denom,mnum=8)),0),
    (toFloat64(sumIf(revenue,mnum=9))-coalesce(toFloat64(sumIf(fot_total,mnum=9)),0)+coalesce(toFloat64(sumIf(taxes_total,mnum=9)),0))/nullIf(toFloat64(sumIf(denom,mnum=9)),0),
    (toFloat64(sumIf(revenue,mnum=10))-coalesce(toFloat64(sumIf(fot_total,mnum=10)),0)+coalesce(toFloat64(sumIf(taxes_total,mnum=10)),0))/nullIf(toFloat64(sumIf(denom,mnum=10)),0),
    (toFloat64(sumIf(revenue,mnum=11))-coalesce(toFloat64(sumIf(fot_total,mnum=11)),0)+coalesce(toFloat64(sumIf(taxes_total,mnum=11)),0))/nullIf(toFloat64(sumIf(denom,mnum=11)),0),
    (toFloat64(sumIf(revenue,mnum=12))-coalesce(toFloat64(sumIf(fot_total,mnum=12)),0)+coalesce(toFloat64(sumIf(taxes_total,mnum=12)),0))/nullIf(toFloat64(sumIf(denom,mnum=12)),0),
    (toFloat64(sum(revenue))-coalesce(toFloat64(sum(fot_total)),0)+coalesce(toFloat64(sum(taxes_total)),0))/nullIf(toFloat64(sum(denom)),0)
FROM monthly
UNION ALL
SELECT 23, 'Накладные (Админы+Управление+аренда+P&L) на ' || lower({{unit}}),
    -toFloat64(sumIf(fixed_attributed,mnum=1))/nullIf(toFloat64(sumIf(denom,mnum=1)),0),
    -toFloat64(sumIf(fixed_attributed,mnum=2))/nullIf(toFloat64(sumIf(denom,mnum=2)),0),
    -toFloat64(sumIf(fixed_attributed,mnum=3))/nullIf(toFloat64(sumIf(denom,mnum=3)),0),
    -toFloat64(sumIf(fixed_attributed,mnum=4))/nullIf(toFloat64(sumIf(denom,mnum=4)),0),
    -toFloat64(sumIf(fixed_attributed,mnum=5))/nullIf(toFloat64(sumIf(denom,mnum=5)),0),
    -toFloat64(sumIf(fixed_attributed,mnum=6))/nullIf(toFloat64(sumIf(denom,mnum=6)),0),
    -toFloat64(sumIf(fixed_attributed,mnum=7))/nullIf(toFloat64(sumIf(denom,mnum=7)),0),
    -toFloat64(sumIf(fixed_attributed,mnum=8))/nullIf(toFloat64(sumIf(denom,mnum=8)),0),
    -toFloat64(sumIf(fixed_attributed,mnum=9))/nullIf(toFloat64(sumIf(denom,mnum=9)),0),
    -toFloat64(sumIf(fixed_attributed,mnum=10))/nullIf(toFloat64(sumIf(denom,mnum=10)),0),
    -toFloat64(sumIf(fixed_attributed,mnum=11))/nullIf(toFloat64(sumIf(denom,mnum=11)),0),
    -toFloat64(sumIf(fixed_attributed,mnum=12))/nullIf(toFloat64(sumIf(denom,mnum=12)),0),
    -toFloat64(sum(fixed_attributed))/nullIf(toFloat64(sum(denom)),0)
FROM monthly
UNION ALL
SELECT 24, 'Маркетинг (ФОТ+реклама+подрядчики+телефония, 80% психиатрия/20% психология) на ' || lower({{unit}}),
    -toFloat64(sumIf(mkt_attributed,mnum=1))/nullIf(toFloat64(sumIf(denom,mnum=1)),0),
    -toFloat64(sumIf(mkt_attributed,mnum=2))/nullIf(toFloat64(sumIf(denom,mnum=2)),0),
    -toFloat64(sumIf(mkt_attributed,mnum=3))/nullIf(toFloat64(sumIf(denom,mnum=3)),0),
    -toFloat64(sumIf(mkt_attributed,mnum=4))/nullIf(toFloat64(sumIf(denom,mnum=4)),0),
    -toFloat64(sumIf(mkt_attributed,mnum=5))/nullIf(toFloat64(sumIf(denom,mnum=5)),0),
    -toFloat64(sumIf(mkt_attributed,mnum=6))/nullIf(toFloat64(sumIf(denom,mnum=6)),0),
    -toFloat64(sumIf(mkt_attributed,mnum=7))/nullIf(toFloat64(sumIf(denom,mnum=7)),0),
    -toFloat64(sumIf(mkt_attributed,mnum=8))/nullIf(toFloat64(sumIf(denom,mnum=8)),0),
    -toFloat64(sumIf(mkt_attributed,mnum=9))/nullIf(toFloat64(sumIf(denom,mnum=9)),0),
    -toFloat64(sumIf(mkt_attributed,mnum=10))/nullIf(toFloat64(sumIf(denom,mnum=10)),0),
    -toFloat64(sumIf(mkt_attributed,mnum=11))/nullIf(toFloat64(sumIf(denom,mnum=11)),0),
    -toFloat64(sumIf(mkt_attributed,mnum=12))/nullIf(toFloat64(sumIf(denom,mnum=12)),0),
    -toFloat64(sum(mkt_attributed))/nullIf(toFloat64(sum(denom)),0)
FROM monthly
UNION ALL
SELECT 25, 'Итого накладные и маркетинг на ' || lower({{unit}}),
    -toFloat64(sumIf(fixed_attributed+mkt_attributed,mnum=1))/nullIf(toFloat64(sumIf(denom,mnum=1)),0),
    -toFloat64(sumIf(fixed_attributed+mkt_attributed,mnum=2))/nullIf(toFloat64(sumIf(denom,mnum=2)),0),
    -toFloat64(sumIf(fixed_attributed+mkt_attributed,mnum=3))/nullIf(toFloat64(sumIf(denom,mnum=3)),0),
    -toFloat64(sumIf(fixed_attributed+mkt_attributed,mnum=4))/nullIf(toFloat64(sumIf(denom,mnum=4)),0),
    -toFloat64(sumIf(fixed_attributed+mkt_attributed,mnum=5))/nullIf(toFloat64(sumIf(denom,mnum=5)),0),
    -toFloat64(sumIf(fixed_attributed+mkt_attributed,mnum=6))/nullIf(toFloat64(sumIf(denom,mnum=6)),0),
    -toFloat64(sumIf(fixed_attributed+mkt_attributed,mnum=7))/nullIf(toFloat64(sumIf(denom,mnum=7)),0),
    -toFloat64(sumIf(fixed_attributed+mkt_attributed,mnum=8))/nullIf(toFloat64(sumIf(denom,mnum=8)),0),
    -toFloat64(sumIf(fixed_attributed+mkt_attributed,mnum=9))/nullIf(toFloat64(sumIf(denom,mnum=9)),0),
    -toFloat64(sumIf(fixed_attributed+mkt_attributed,mnum=10))/nullIf(toFloat64(sumIf(denom,mnum=10)),0),
    -toFloat64(sumIf(fixed_attributed+mkt_attributed,mnum=11))/nullIf(toFloat64(sumIf(denom,mnum=11)),0),
    -toFloat64(sumIf(fixed_attributed+mkt_attributed,mnum=12))/nullIf(toFloat64(sumIf(denom,mnum=12)),0),
    -toFloat64(sum(fixed_attributed+mkt_attributed))/nullIf(toFloat64(sum(denom)),0)
FROM monthly
UNION ALL
SELECT 26, 'Прибыль после ФОТ и накладных на ' || lower({{unit}}),
    (toFloat64(sumIf(revenue,mnum=1))-coalesce(toFloat64(sumIf(fot_own,mnum=1)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=1)),0)+coalesce(toFloat64(sumIf(fixed_attributed,mnum=1)),0)+coalesce(toFloat64(sumIf(mkt_attributed,mnum=1)),0))/nullIf(toFloat64(sumIf(denom,mnum=1)),0),
    (toFloat64(sumIf(revenue,mnum=2))-coalesce(toFloat64(sumIf(fot_own,mnum=2)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=2)),0)+coalesce(toFloat64(sumIf(fixed_attributed,mnum=2)),0)+coalesce(toFloat64(sumIf(mkt_attributed,mnum=2)),0))/nullIf(toFloat64(sumIf(denom,mnum=2)),0),
    (toFloat64(sumIf(revenue,mnum=3))-coalesce(toFloat64(sumIf(fot_own,mnum=3)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=3)),0)+coalesce(toFloat64(sumIf(fixed_attributed,mnum=3)),0)+coalesce(toFloat64(sumIf(mkt_attributed,mnum=3)),0))/nullIf(toFloat64(sumIf(denom,mnum=3)),0),
    (toFloat64(sumIf(revenue,mnum=4))-coalesce(toFloat64(sumIf(fot_own,mnum=4)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=4)),0)+coalesce(toFloat64(sumIf(fixed_attributed,mnum=4)),0)+coalesce(toFloat64(sumIf(mkt_attributed,mnum=4)),0))/nullIf(toFloat64(sumIf(denom,mnum=4)),0),
    (toFloat64(sumIf(revenue,mnum=5))-coalesce(toFloat64(sumIf(fot_own,mnum=5)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=5)),0)+coalesce(toFloat64(sumIf(fixed_attributed,mnum=5)),0)+coalesce(toFloat64(sumIf(mkt_attributed,mnum=5)),0))/nullIf(toFloat64(sumIf(denom,mnum=5)),0),
    (toFloat64(sumIf(revenue,mnum=6))-coalesce(toFloat64(sumIf(fot_own,mnum=6)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=6)),0)+coalesce(toFloat64(sumIf(fixed_attributed,mnum=6)),0)+coalesce(toFloat64(sumIf(mkt_attributed,mnum=6)),0))/nullIf(toFloat64(sumIf(denom,mnum=6)),0),
    (toFloat64(sumIf(revenue,mnum=7))-coalesce(toFloat64(sumIf(fot_own,mnum=7)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=7)),0)+coalesce(toFloat64(sumIf(fixed_attributed,mnum=7)),0)+coalesce(toFloat64(sumIf(mkt_attributed,mnum=7)),0))/nullIf(toFloat64(sumIf(denom,mnum=7)),0),
    (toFloat64(sumIf(revenue,mnum=8))-coalesce(toFloat64(sumIf(fot_own,mnum=8)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=8)),0)+coalesce(toFloat64(sumIf(fixed_attributed,mnum=8)),0)+coalesce(toFloat64(sumIf(mkt_attributed,mnum=8)),0))/nullIf(toFloat64(sumIf(denom,mnum=8)),0),
    (toFloat64(sumIf(revenue,mnum=9))-coalesce(toFloat64(sumIf(fot_own,mnum=9)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=9)),0)+coalesce(toFloat64(sumIf(fixed_attributed,mnum=9)),0)+coalesce(toFloat64(sumIf(mkt_attributed,mnum=9)),0))/nullIf(toFloat64(sumIf(denom,mnum=9)),0),
    (toFloat64(sumIf(revenue,mnum=10))-coalesce(toFloat64(sumIf(fot_own,mnum=10)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=10)),0)+coalesce(toFloat64(sumIf(fixed_attributed,mnum=10)),0)+coalesce(toFloat64(sumIf(mkt_attributed,mnum=10)),0))/nullIf(toFloat64(sumIf(denom,mnum=10)),0),
    (toFloat64(sumIf(revenue,mnum=11))-coalesce(toFloat64(sumIf(fot_own,mnum=11)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=11)),0)+coalesce(toFloat64(sumIf(fixed_attributed,mnum=11)),0)+coalesce(toFloat64(sumIf(mkt_attributed,mnum=11)),0))/nullIf(toFloat64(sumIf(denom,mnum=11)),0),
    (toFloat64(sumIf(revenue,mnum=12))-coalesce(toFloat64(sumIf(fot_own,mnum=12)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=12)),0)+coalesce(toFloat64(sumIf(fixed_attributed,mnum=12)),0)+coalesce(toFloat64(sumIf(mkt_attributed,mnum=12)),0))/nullIf(toFloat64(sumIf(denom,mnum=12)),0),
    (toFloat64(sum(revenue))-coalesce(toFloat64(sum(fot_own)),0)+coalesce(toFloat64(sum(taxes_own)),0)+coalesce(toFloat64(sum(fixed_attributed)),0)+coalesce(toFloat64(sum(mkt_attributed)),0))/nullIf(toFloat64(sum(denom)),0)
FROM monthly
) ORDER BY rn
-- 2026-09-19: без этой строки запрос падает с "Too many optimizations
-- applied to query plan. Current limit 10000" (TOO_MANY_QUERY_PLAN_OPTIMIZATIONS)
-- — 26-way UNION ALL, где каждая ветка тянет monthly (а через неё —
-- overhead_by_month/filtered_overhead/base с оконной функцией), уже
-- упирается в дефолтный лимит планировщика ClickHouse; до добавления
-- строк накладных/маркетинга (24 ветки) лимита хватало. Проверено на
-- проде (2026-09-19, clickhouse-client, все параметры карточки).
SETTINGS query_plan_max_optimizations_to_apply = 100000