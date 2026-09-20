-- Metabase: native SQL карточка дашборда «Юнит-экономика | Визиты»
-- (было id 183 «Таблица - Реальт - Помесячная юнитка (по врачам,
-- корректная)», единый дашборд id 7 «Юнит-экономика» с параметром
-- unit). 2026-09-19: дашборд разделён на два отдельных — «Юнит-
-- экономика | Клиенты» (realt_unitka_clients.sql) и «Юнит-экономика |
-- Визиты» (realt_unitka_visits.sql, этот/тот файл) — параметр unit
-- убран, знаменатель зафиксирован. Набор строк перестроен в чистый
-- P&L-каскад по просьбе владельца: Выручка → ФОТ (весь) → ФОТ Психиатры
-- → Взносы и НДФЛ врачей (Психиатры/Психологи/Остальные=ШАА) → Прибыль
-- и Маржа после Врачей → ФОТ/Взносы Админов → Аренда и коммуналка →
-- Прибыль и Маржа после Админа → Маркетинг → САС → Управление → EBITDA.
-- Оба файла идентичны по структуре и формулам, отличаются только
-- знаменателем (clients/visits) и суффиксом подписи строк — см.
-- docs/formulas/realt.tex, раздел «Каскад Юнит-экономики» для полного
-- разбора формул и допущений (что считается Family A/по врачу-напрямую
-- vs Family B/клиника-целиком-атрибуция).
-- Параметры дашборда (без изменений): year, include_shaa, doctor_type,
-- doctor_name, client_type.
-- Унаследованные от предыдущей версии файла ГОЧТЯ (актуальны и здесь):
-- голая строка-комментарий "--" без пробела/текста после ломает разбор
-- параметров в ClickHouse JDBC-драйвере Metabase — после "--" всегда
-- пробел или текст. То же для двойных фигурных скобок вокруг имени
-- параметра в тексте комментария (движок ищет их и там) — поэтому
-- параметры дашборда упоминаются здесь простым именем без скобок.
-- 2026-09-19: старые строки «ФОТ <роль> — Проценты/Оклад+Бонус» и
-- «ФОТ Администраторы/Управление/Маркетинг по роли» (отфильтрованные по
-- doctor_name/employee_id, зануляющиеся при выбранном не-администраторе
-- враче — Family A) убраны из вывода. Для Админов/Аренды/Управления/
-- Маркетинга в каскаде используется Family B (клиника целиком, ставка на
-- визит своего этажа/роли, атрибутируется на видимый срез визитов) — она
-- единственная математически сходится с P&L владельца построчно
-- (согласовано 2026-09-19, раньше — раздел «Накладные расходы» здесь же).
-- 2026-09-20 (третья итерация): ФОТ врачей ТОЖЕ переведён на Family B
-- (ставка на визит своего КОНКРЕТНОГО врача, не роли — employee_id) —
-- см. блок doctor_visits_m/doctor_payroll_m/doctor_rates ниже. Family A
-- по врачам (реальная начисленная зарплата, не зависящая от
-- {{client_type}}) вызывала уход «Прибыль после Врачей» в минус при
-- {{client_type}}='Повторный' — полный ФОТ делился на маленькое число
-- повторных клиентов. Теперь ВСЕ статьи каскада (Врачи/Админы/Аренда/
-- Управление/Маркетинг) — единая методика Family B.
-- Знак: ФОТ (accrued_total) в источнике позитивный, ndfl/contributions
-- обычно отрицательные (см. schema_realt_gsheets.sql). Все cost-строки
-- этого дашборда показываются как ПОЗИТИВНЫЕ величины (явно негируются
-- там, где внутренняя величина отрицательна) — единообразно, в отличие
-- от прежней версии, где «Налоги и взносы» показывались без флипа знака
-- (отрицательным числом), а «Накладные»/«Маркетинг» — с флипом.
-- 2026-09-20, вторая итерация правок по фидбэку владельца:
--   * добавлена «ФОТ Психологи» (была вычислена для fot_own, просто не
--     показывалась отдельной строкой);
--   * убрана строка налогов ШАА («Остальные врачи») — ФОТ ШАА и его
--     налоги всё равно в fot_own/taxes_own, просто без своей строки;
--   * «Маржа Врачей/Кабинетов» → «Маржинальность ..., %» (без суффикса
--     unit — одно и то же число на обоих дашбордах, как «Доля ФОТ в
--     выручке, %» раньше);
--   * добавлена «Маржинальность EBITDA, %» (то же самое, для EBITDA);
--   * «ФОТ | unit» (весь ФОТ клиники) и «САС» УБРАНЫ с этого дашборда —
--     перенесены на «Ежемесячные метрики» (дашборд id 8, карточка 186),
--     где это компанийские KPI без разбивки по врачу/типу клиента;
--   * «Маркетинг» переписан: раньше атрибутировался на КАЖДЫЙ визит своей
--     роли (80/20 психиатрия/психология, знаменатель — визиты роли
--     целиком), теперь — ТОЛЬКО на визит с visit_seq=1 (первый визит
--     клиента за всю историю), знаменатель — новые клиенты роли, а не
--     визиты. Смысл: маркетинг это стоимость ПРИВЛЕЧЕНИЯ, повторные
--     визиты её не несут. При {{client_type}}='Повторный' строка
--     «Маркетинг» почти всегда обнуляется (см. ГОЧТЯ ниже про
--     mvisits vs visit_seq — не 100% гарантированно, но близко).

WITH
base AS (
    SELECT
        v.card_number    AS card_number,
        v.month          AS month,
        v.employee_id    AS employee_id,
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
-- ФОТ врачей (2026-09-20, переписано по просьбе владельца): раньше это
-- была Family A — реальная начисленная зарплата врача за месяц (факт),
-- не зависящая от {{client_type}} — из-за этого "Прибыль после Врачей"
-- уходила в глубокий минус при {{client_type}}='Повторный' (полный ФОТ
-- делился на маленькое число повторных клиентов, см. историю решения в
-- git/вики). Теперь ФОТ врачей — Family B, как Админы/Аренда/Маркетинг:
-- ставка на визит СВОЕГО врача (не роли — именно этого employee_id),
-- клиника целиком, атрибуция суммируется по видимым (после ВСЕХ
-- фильтров, включая client_type) визитам ЭТОГО врача. У клиента с
-- несколькими визитами за месяц сумма ФОТ на него — это сумма ставок
-- по каждому из его визитов (могут быть у разных врачей).
doctor_visits_m AS (
    -- Визиты КАЖДОГО врача за месяц, клиника целиком (год + тумблер ШАА,
    -- БЕЗ doctor_type/doctor_name/client_type — ставка не должна
    -- зависеть от текущего фильтра, см. тот же принцип в Family B ниже).
    SELECT
        employee_id,
        toMonth(month) AS mnum,
        count() AS visits
    FROM realt_visits_categorized
    WHERE toYear(month) = toInt32({{year}})
      AND ( {{include_shaa}} = 'Да' OR role_group != 'ФОТ ШАА' )
      AND employee_id IS NOT NULL AND employee_id != ''
      AND role_group IN ('ФОТ Психиатры', 'ФОТ Психологи', 'ФОТ ШАА')
    GROUP BY employee_id, mnum
),
doctor_payroll_m AS (
    SELECT
        employee_id,
        toMonth(month) AS mnum,
        sum(accrued_total)                                  AS fot,
        sum(coalesce(ndfl, 0) + coalesce(contributions, 0)) AS taxes
    FROM realt_payroll_categorized
    WHERE toYear(month) = toInt32({{year}})
      AND ( {{include_shaa}} = 'Да' OR role_group != 'ФОТ ШАА' )
      AND role_group IN ('ФОТ Психиатры', 'ФОТ Психологи', 'ФОТ ШАА')
      AND employee_id IS NOT NULL AND employee_id != ''
    GROUP BY employee_id, mnum
),
doctor_rates AS (
    -- Ставка ФОТ/налогов НА ОДИН ВИЗИТ этого конкретного врача.
    SELECT
        dv.employee_id AS employee_id,
        dv.mnum AS mnum,
        coalesce(dp.fot,0)   / nullIf(dv.visits,0) AS fot_rate,
        coalesce(dp.taxes,0) / nullIf(dv.visits,0) AS tax_rate
    FROM doctor_visits_m dv
    LEFT JOIN doctor_payroll_m dp ON dv.employee_id = dp.employee_id AND dv.mnum = dp.mnum
),
filtered_doctor_fot AS (
    -- Атрибуция: каждому ВИДИМОМУ (после doctor_type/doctor_name/
    -- client_type) визиту присваивается ставка ЕГО врача.
    SELECT
        toMonth(f.month) AS mnum,
        f.role_group AS role_group,
        coalesce(dr.fot_rate,0) AS fot_rate_for_visit,
        coalesce(dr.tax_rate,0) AS tax_rate_for_visit
    FROM filtered f
    LEFT JOIN doctor_rates dr ON f.employee_id = dr.employee_id AND toMonth(f.month) = dr.mnum
),
doctor_fot_by_month AS (
    SELECT
        mnum,
        sumIf(fot_rate_for_visit, role_group = 'ФОТ Психиатры') AS psy_total,
        sumIf(fot_rate_for_visit, role_group = 'ФОТ Психологи') AS pso_total,
        sumIf(fot_rate_for_visit, role_group = 'ФОТ ШАА')       AS shaa_total,
        sumIf(tax_rate_for_visit, role_group = 'ФОТ Психиатры') AS taxes_psy,
        sumIf(tax_rate_for_visit, role_group = 'ФОТ Психологи') AS taxes_pso,
        sumIf(tax_rate_for_visit, role_group = 'ФОТ ШАА')       AS taxes_shaa
    FROM filtered_doctor_fot
    GROUP BY mnum
),
-- Family B: накладные расходы и маркетинг — ВСЕГДА считаются по клинике
-- целиком (год + тумблер include_shaa), НЕ фильтруются по doctor_name/
-- doctor_type/client_type — расходы физически не привязаны к конкретному
-- врачу. Ставка на визит своего этажа/роли считается здесь клиника-
-- целиком, атрибуция на видимый срез — ниже, в filtered_overhead.
-- Подробный разбор (почему по этажам, а не по роли визита; откуда взялась
-- методика) — docs/formulas/realt.tex, раздел «Накладные расходы».
overhead_payroll AS (
    -- Читаем realt_payroll НАПРЯМУЮ (не realt_payroll_categorized) — та
    -- VIEW подменяет role на "ФОТ ШАА" для department='ШАА', а здесь
    -- нужна ИСХОДНАЯ роль (ФОТ Администраторы и т.д.) у ШАА-сотрудников
    -- тоже, плюс сырой department для разбивки по этажу.
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
    -- роли — знаменатели ставок не зависят от того, какой врач/тип
    -- врача/тип клиента сейчас выбран на экране.
    -- new_clients_psy/pso (2026-09-20): визиты с visit_seq=1 (ПЕРВЫЙ визит
    -- клиента за всю историю) той же роли — знаменатель для ставки
    -- маркетинга, теперь считается НА НОВОГО КЛИЕНТА, а не на визит (см.
    -- filtered_overhead ниже) — так реклама привязывается к привлечению
    -- нового клиента и не размазывается на его повторные визиты.
    SELECT
        toMonth(month)                                        AS mnum,
        countIf(role_group IN ('ФОТ Психиатры', 'ФОТ ШАА'))    AS visits_psy,
        countIf(role_group = 'ФОТ Психологи')                  AS visits_pso,
        countIf(visit_seq = 1 AND role_group IN ('ФОТ Психиатры', 'ФОТ ШАА')) AS new_clients_psy,
        countIf(visit_seq = 1 AND role_group = 'ФОТ Психологи')               AS new_clients_pso,
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
    -- НЕ включаем — формула ещё не согласована с владельцем, поэтому
    -- итоговая строка называется EBITDA, а не «чистая прибыль».
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
    -- Ставки клиника целиком. rent_rate/adm_tax_rate/upr_rate/mkt_*_rate —
    -- знак как в источнике (отрицательные, это расход); adm_fot_rate — НЕ
    -- негируется (остаётся позитивной величиной ФОТ), чтобы строка «ФОТ
    -- Администраторы» ниже показывалась как позитивный расход без доп.
    -- флипа. mkt_psy_rate/mkt_pso_rate (2026-09-20, переписаны) — теперь
    -- ставка НА НОВОГО КЛИЕНТА своей роли (не на визит) — маркетинг
    -- считается только на привлечение, повторные визиты его не несут (см.
    -- filtered_overhead ниже, где ставка присваивается только визиту с
    -- visit_seq=1). При выбранном {{client_type}}='Повторный' видимые
    -- визиты почти всегда имеют visit_seq!=1 — строка «Маркетинг»
    -- обнуляется (кроме редкого края: новый клиент, у которого 2+ визита
    -- уже в месяце дебюта — тогда один из них попадёт под «Повторный» по
    -- mvisits, но всё ещё будет visit_seq=1 и понесёт ставку — это не
    -- баг, mvisits и visit_seq — разные оси: mvisits считает визиты
    -- ЭТОГО клиента В ЭТОМ месяце, visit_seq — порядковый номер визита за
    -- всю историю клиента).
    SELECT
        cv.mnum AS mnum,
        coalesce(pl.rent_2et, 0)  / nullIf(cv.visits_2et, 0)  AS rent_rate_2et,
        coalesce(pl.rent_3et, 0)  / nullIf(cv.visits_3et, 0)  AS rent_rate_3et,
        coalesce(pl.rent_shaa, 0) / nullIf(cv.visits_shaa, 0) AS rent_rate_shaa,
        coalesce(op.adm_fot_2et, 0)  / nullIf(cv.visits_2et, 0)  AS adm_fot_rate_2et,
        coalesce(op.adm_fot_3et, 0)  / nullIf(cv.visits_3et, 0)  AS adm_fot_rate_3et,
        coalesce(op.adm_fot_shaa, 0) / nullIf(cv.visits_shaa, 0) AS adm_fot_rate_shaa,
        coalesce(op.adm_taxes_2et, 0)  / nullIf(cv.visits_2et, 0)  AS adm_tax_rate_2et,
        coalesce(op.adm_taxes_3et, 0)  / nullIf(cv.visits_3et, 0)  AS adm_tax_rate_3et,
        coalesce(op.adm_taxes_shaa, 0) / nullIf(cv.visits_shaa, 0) AS adm_tax_rate_shaa,
        (
            ( -coalesce(op.upr_fot, 0) + coalesce(op.upr_taxes, 0) + coalesce(pl.admin_misc_cost, 0) + coalesce(pl.credit_amort_cost, 0) )
            * coalesce(cv.revenue_2et, 0) / nullIf(coalesce(cv.revenue_2et, 0) + coalesce(cv.revenue_3et, 0), 0)
        ) / nullIf(cv.visits_2et, 0) AS upr_rate_2et,
        (
            ( -coalesce(op.upr_fot, 0) + coalesce(op.upr_taxes, 0) + coalesce(pl.admin_misc_cost, 0) + coalesce(pl.credit_amort_cost, 0) )
            * coalesce(cv.revenue_3et, 0) / nullIf(coalesce(cv.revenue_2et, 0) + coalesce(cv.revenue_3et, 0), 0)
        ) / nullIf(cv.visits_3et, 0) AS upr_rate_3et,
        0.8 * ( -coalesce(op.mkt_fot, 0) + coalesce(op.mkt_taxes, 0) + coalesce(pl.mkt_pl_cost, 0) )
            / nullIf(cv.new_clients_psy, 0) AS mkt_psy_rate,
        0.2 * ( -coalesce(op.mkt_fot, 0) + coalesce(op.mkt_taxes, 0) + coalesce(pl.mkt_pl_cost, 0) )
            / nullIf(cv.new_clients_pso, 0) AS mkt_pso_rate
    FROM clinic_visits cv
    LEFT JOIN overhead_payroll op ON cv.mnum = op.mnum
    LEFT JOIN pl_overhead pl ON cv.mnum = pl.mnum
),
filtered_overhead AS (
    -- Атрибуция: каждому визиту из ТЕКУЩЕГО фильтра присваивается ставка
    -- ЕГО этажа (аренда/админ-ФОТ/админ-налоги/управление) и ЕГО роли
    -- (маркетинг). Сумма по видимым визитам ниже даёт «долю» текущего
    -- среза — так же, как было в предыдущей версии файла, только
    -- аренда/админ-ФОТ/админ-налоги теперь отдельные ставки, а не одна
    -- слитая fixed_rate.
    SELECT
        toMonth(f.month) AS mnum,
        multiIf(
            f.visit_floor = '2 этаж', coalesce(om.rent_rate_2et,0),
            f.visit_floor = '3 этаж', coalesce(om.rent_rate_3et,0),
            f.visit_floor = 'ШАА',    coalesce(om.rent_rate_shaa,0),
            0
        ) AS rent_rate_for_visit,
        multiIf(
            f.visit_floor = '2 этаж', coalesce(om.adm_fot_rate_2et,0),
            f.visit_floor = '3 этаж', coalesce(om.adm_fot_rate_3et,0),
            f.visit_floor = 'ШАА',    coalesce(om.adm_fot_rate_shaa,0),
            0
        ) AS adm_fot_rate_for_visit,
        multiIf(
            f.visit_floor = '2 этаж', coalesce(om.adm_tax_rate_2et,0),
            f.visit_floor = '3 этаж', coalesce(om.adm_tax_rate_3et,0),
            f.visit_floor = 'ШАА',    coalesce(om.adm_tax_rate_shaa,0),
            0
        ) AS adm_tax_rate_for_visit,
        multiIf(
            f.visit_floor = '2 этаж', coalesce(om.upr_rate_2et,0),
            f.visit_floor = '3 этаж', coalesce(om.upr_rate_3et,0),
            0
        ) AS upr_rate_for_visit,
        multiIf(
            f.visit_seq != 1, 0,
            f.role_group IN ('ФОТ Психиатры', 'ФОТ ШАА'), coalesce(om.mkt_psy_rate,0),
            f.role_group = 'ФОТ Психологи', coalesce(om.mkt_pso_rate,0),
            0
        ) AS mkt_rate_for_visit
    FROM filtered f
    LEFT JOIN overhead_monthly om ON toMonth(f.month) = om.mnum
),
overhead_by_month AS (
    SELECT
        mnum AS mnum,
        sum(rent_rate_for_visit)    AS rent_attributed,
        sum(adm_fot_rate_for_visit) AS adm_fot_attributed,
        sum(adm_tax_rate_for_visit) AS adm_tax_attributed,
        sum(upr_rate_for_visit)     AS upr_attributed,
        sum(mkt_rate_for_visit)     AS mkt_attributed
    FROM filtered_overhead
    GROUP BY mnum
),
monthly AS (
    SELECT
        r.mnum AS mnum,
        r.revenue AS revenue, r.visits AS visits, r.clients AS clients, r.new_clients AS new_clients,
        p.psy_total AS psy_total,
        p.pso_total AS pso_total,
        p.shaa_total AS shaa_total,
        p.taxes_psy AS taxes_psy,
        p.taxes_pso AS taxes_pso,
        p.taxes_shaa AS taxes_shaa,
        -- fot_own/taxes_own — ТОЛЬКО клинические роли (Психиатры/
        -- Психологи/ШАА), см. Family A/B выше — нужны для каскада
        -- «Прибыль после Врачей»/«EBITDA», без Админов/Управления/
        -- Маркетинга (те приходят из Family B ниже).
        (coalesce(p.psy_total,0) + coalesce(p.pso_total,0) + coalesce(p.shaa_total,0)) AS fot_own,
        (coalesce(p.taxes_psy,0) + coalesce(p.taxes_pso,0) + coalesce(p.taxes_shaa,0)) AS taxes_own,
        o.rent_attributed    AS rent_attributed,
        o.adm_fot_attributed AS adm_fot_attributed,
        o.adm_tax_attributed AS adm_tax_attributed,
        o.upr_attributed     AS upr_attributed,
        o.mkt_attributed     AS mkt_attributed,
        r.visits AS denom
    FROM monthly_rev r
    FULL OUTER JOIN doctor_fot_by_month p ON r.mnum = p.mnum
    LEFT JOIN overhead_by_month o ON r.mnum = o.mnum
)

SELECT "Метрика", "Янв", "Фев", "Мар", "Апр", "Май", "Июн", "Июл", "Авг", "Сен", "Окт", "Ноя", "Дек", "За год"
FROM (
SELECT 1 AS rn, 'Средний чек' AS "Метрика",
    round(toFloat64(sumIf(revenue,mnum=1))/nullIf(toFloat64(sumIf(visits,mnum=1)),0), 0) AS "Янв",
    round(toFloat64(sumIf(revenue,mnum=2))/nullIf(toFloat64(sumIf(visits,mnum=2)),0), 0) AS "Фев",
    round(toFloat64(sumIf(revenue,mnum=3))/nullIf(toFloat64(sumIf(visits,mnum=3)),0), 0) AS "Мар",
    round(toFloat64(sumIf(revenue,mnum=4))/nullIf(toFloat64(sumIf(visits,mnum=4)),0), 0) AS "Апр",
    round(toFloat64(sumIf(revenue,mnum=5))/nullIf(toFloat64(sumIf(visits,mnum=5)),0), 0) AS "Май",
    round(toFloat64(sumIf(revenue,mnum=6))/nullIf(toFloat64(sumIf(visits,mnum=6)),0), 0) AS "Июн",
    round(toFloat64(sumIf(revenue,mnum=7))/nullIf(toFloat64(sumIf(visits,mnum=7)),0), 0) AS "Июл",
    round(toFloat64(sumIf(revenue,mnum=8))/nullIf(toFloat64(sumIf(visits,mnum=8)),0), 0) AS "Авг",
    round(toFloat64(sumIf(revenue,mnum=9))/nullIf(toFloat64(sumIf(visits,mnum=9)),0), 0) AS "Сен",
    round(toFloat64(sumIf(revenue,mnum=10))/nullIf(toFloat64(sumIf(visits,mnum=10)),0), 0) AS "Окт",
    round(toFloat64(sumIf(revenue,mnum=11))/nullIf(toFloat64(sumIf(visits,mnum=11)),0), 0) AS "Ноя",
    round(toFloat64(sumIf(revenue,mnum=12))/nullIf(toFloat64(sumIf(visits,mnum=12)),0), 0) AS "Дек",
    round(toFloat64(sum(revenue))/nullIf(toFloat64(sum(visits)),0), 0) AS "За год"
FROM monthly
UNION ALL
SELECT 2 AS rn, 'Визиты' AS "Метрика",
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
SELECT 3 AS rn, 'Клиенты' AS "Метрика",
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
SELECT 4 AS rn, 'Новые клиенты' AS "Метрика",
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
SELECT 5 AS rn, '' AS "Метрика",
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL
FROM monthly LIMIT 1
UNION ALL
SELECT 6 AS rn, 'Выручка | Визиты' AS "Метрика",
    round(toFloat64(sumIf(revenue,mnum=1))/nullIf(toFloat64(sumIf(visits,mnum=1)),0), 0),
    round(toFloat64(sumIf(revenue,mnum=2))/nullIf(toFloat64(sumIf(visits,mnum=2)),0), 0),
    round(toFloat64(sumIf(revenue,mnum=3))/nullIf(toFloat64(sumIf(visits,mnum=3)),0), 0),
    round(toFloat64(sumIf(revenue,mnum=4))/nullIf(toFloat64(sumIf(visits,mnum=4)),0), 0),
    round(toFloat64(sumIf(revenue,mnum=5))/nullIf(toFloat64(sumIf(visits,mnum=5)),0), 0),
    round(toFloat64(sumIf(revenue,mnum=6))/nullIf(toFloat64(sumIf(visits,mnum=6)),0), 0),
    round(toFloat64(sumIf(revenue,mnum=7))/nullIf(toFloat64(sumIf(visits,mnum=7)),0), 0),
    round(toFloat64(sumIf(revenue,mnum=8))/nullIf(toFloat64(sumIf(visits,mnum=8)),0), 0),
    round(toFloat64(sumIf(revenue,mnum=9))/nullIf(toFloat64(sumIf(visits,mnum=9)),0), 0),
    round(toFloat64(sumIf(revenue,mnum=10))/nullIf(toFloat64(sumIf(visits,mnum=10)),0), 0),
    round(toFloat64(sumIf(revenue,mnum=11))/nullIf(toFloat64(sumIf(visits,mnum=11)),0), 0),
    round(toFloat64(sumIf(revenue,mnum=12))/nullIf(toFloat64(sumIf(visits,mnum=12)),0), 0),
    round(toFloat64(sum(revenue))/nullIf(toFloat64(sum(visits)),0), 0)
FROM monthly
UNION ALL
SELECT 7 AS rn, 'ФОТ Психиатры | Визиты' AS "Метрика",
    round(coalesce(toFloat64(sumIf(psy_total,mnum=1)),0)/nullIf(toFloat64(sumIf(visits,mnum=1)),0), 0),
    round(coalesce(toFloat64(sumIf(psy_total,mnum=2)),0)/nullIf(toFloat64(sumIf(visits,mnum=2)),0), 0),
    round(coalesce(toFloat64(sumIf(psy_total,mnum=3)),0)/nullIf(toFloat64(sumIf(visits,mnum=3)),0), 0),
    round(coalesce(toFloat64(sumIf(psy_total,mnum=4)),0)/nullIf(toFloat64(sumIf(visits,mnum=4)),0), 0),
    round(coalesce(toFloat64(sumIf(psy_total,mnum=5)),0)/nullIf(toFloat64(sumIf(visits,mnum=5)),0), 0),
    round(coalesce(toFloat64(sumIf(psy_total,mnum=6)),0)/nullIf(toFloat64(sumIf(visits,mnum=6)),0), 0),
    round(coalesce(toFloat64(sumIf(psy_total,mnum=7)),0)/nullIf(toFloat64(sumIf(visits,mnum=7)),0), 0),
    round(coalesce(toFloat64(sumIf(psy_total,mnum=8)),0)/nullIf(toFloat64(sumIf(visits,mnum=8)),0), 0),
    round(coalesce(toFloat64(sumIf(psy_total,mnum=9)),0)/nullIf(toFloat64(sumIf(visits,mnum=9)),0), 0),
    round(coalesce(toFloat64(sumIf(psy_total,mnum=10)),0)/nullIf(toFloat64(sumIf(visits,mnum=10)),0), 0),
    round(coalesce(toFloat64(sumIf(psy_total,mnum=11)),0)/nullIf(toFloat64(sumIf(visits,mnum=11)),0), 0),
    round(coalesce(toFloat64(sumIf(psy_total,mnum=12)),0)/nullIf(toFloat64(sumIf(visits,mnum=12)),0), 0),
    round(coalesce(toFloat64(sum(psy_total)),0)/nullIf(toFloat64(sum(visits)),0), 0)
FROM monthly
UNION ALL
SELECT 8 AS rn, 'ФОТ Психиатры, % от выручки' AS "Метрика",
    round(coalesce(toFloat64(sumIf(psy_total,mnum=1)),0)/nullIf(toFloat64(sumIf(revenue,mnum=1)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(psy_total,mnum=2)),0)/nullIf(toFloat64(sumIf(revenue,mnum=2)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(psy_total,mnum=3)),0)/nullIf(toFloat64(sumIf(revenue,mnum=3)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(psy_total,mnum=4)),0)/nullIf(toFloat64(sumIf(revenue,mnum=4)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(psy_total,mnum=5)),0)/nullIf(toFloat64(sumIf(revenue,mnum=5)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(psy_total,mnum=6)),0)/nullIf(toFloat64(sumIf(revenue,mnum=6)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(psy_total,mnum=7)),0)/nullIf(toFloat64(sumIf(revenue,mnum=7)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(psy_total,mnum=8)),0)/nullIf(toFloat64(sumIf(revenue,mnum=8)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(psy_total,mnum=9)),0)/nullIf(toFloat64(sumIf(revenue,mnum=9)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(psy_total,mnum=10)),0)/nullIf(toFloat64(sumIf(revenue,mnum=10)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(psy_total,mnum=11)),0)/nullIf(toFloat64(sumIf(revenue,mnum=11)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(psy_total,mnum=12)),0)/nullIf(toFloat64(sumIf(revenue,mnum=12)),0)*100, 1),
    round(coalesce(toFloat64(sum(psy_total)),0)/nullIf(toFloat64(sum(revenue)),0)*100, 1)
FROM monthly
UNION ALL
SELECT 9 AS rn, 'ФОТ Психологи | Визиты' AS "Метрика",
    round(coalesce(toFloat64(sumIf(pso_total,mnum=1)),0)/nullIf(toFloat64(sumIf(visits,mnum=1)),0), 0),
    round(coalesce(toFloat64(sumIf(pso_total,mnum=2)),0)/nullIf(toFloat64(sumIf(visits,mnum=2)),0), 0),
    round(coalesce(toFloat64(sumIf(pso_total,mnum=3)),0)/nullIf(toFloat64(sumIf(visits,mnum=3)),0), 0),
    round(coalesce(toFloat64(sumIf(pso_total,mnum=4)),0)/nullIf(toFloat64(sumIf(visits,mnum=4)),0), 0),
    round(coalesce(toFloat64(sumIf(pso_total,mnum=5)),0)/nullIf(toFloat64(sumIf(visits,mnum=5)),0), 0),
    round(coalesce(toFloat64(sumIf(pso_total,mnum=6)),0)/nullIf(toFloat64(sumIf(visits,mnum=6)),0), 0),
    round(coalesce(toFloat64(sumIf(pso_total,mnum=7)),0)/nullIf(toFloat64(sumIf(visits,mnum=7)),0), 0),
    round(coalesce(toFloat64(sumIf(pso_total,mnum=8)),0)/nullIf(toFloat64(sumIf(visits,mnum=8)),0), 0),
    round(coalesce(toFloat64(sumIf(pso_total,mnum=9)),0)/nullIf(toFloat64(sumIf(visits,mnum=9)),0), 0),
    round(coalesce(toFloat64(sumIf(pso_total,mnum=10)),0)/nullIf(toFloat64(sumIf(visits,mnum=10)),0), 0),
    round(coalesce(toFloat64(sumIf(pso_total,mnum=11)),0)/nullIf(toFloat64(sumIf(visits,mnum=11)),0), 0),
    round(coalesce(toFloat64(sumIf(pso_total,mnum=12)),0)/nullIf(toFloat64(sumIf(visits,mnum=12)),0), 0),
    round(coalesce(toFloat64(sum(pso_total)),0)/nullIf(toFloat64(sum(visits)),0), 0)
FROM monthly
UNION ALL
SELECT 10 AS rn, 'ФОТ Психологи, % от выручки' AS "Метрика",
    round(coalesce(toFloat64(sumIf(pso_total,mnum=1)),0)/nullIf(toFloat64(sumIf(revenue,mnum=1)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(pso_total,mnum=2)),0)/nullIf(toFloat64(sumIf(revenue,mnum=2)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(pso_total,mnum=3)),0)/nullIf(toFloat64(sumIf(revenue,mnum=3)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(pso_total,mnum=4)),0)/nullIf(toFloat64(sumIf(revenue,mnum=4)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(pso_total,mnum=5)),0)/nullIf(toFloat64(sumIf(revenue,mnum=5)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(pso_total,mnum=6)),0)/nullIf(toFloat64(sumIf(revenue,mnum=6)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(pso_total,mnum=7)),0)/nullIf(toFloat64(sumIf(revenue,mnum=7)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(pso_total,mnum=8)),0)/nullIf(toFloat64(sumIf(revenue,mnum=8)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(pso_total,mnum=9)),0)/nullIf(toFloat64(sumIf(revenue,mnum=9)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(pso_total,mnum=10)),0)/nullIf(toFloat64(sumIf(revenue,mnum=10)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(pso_total,mnum=11)),0)/nullIf(toFloat64(sumIf(revenue,mnum=11)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(pso_total,mnum=12)),0)/nullIf(toFloat64(sumIf(revenue,mnum=12)),0)*100, 1),
    round(coalesce(toFloat64(sum(pso_total)),0)/nullIf(toFloat64(sum(revenue)),0)*100, 1)
FROM monthly
UNION ALL
SELECT 11 AS rn, 'ФОТ ШАА | Визиты' AS "Метрика",
    round(coalesce(toFloat64(sumIf(shaa_total,mnum=1)),0)/nullIf(toFloat64(sumIf(visits,mnum=1)),0), 0),
    round(coalesce(toFloat64(sumIf(shaa_total,mnum=2)),0)/nullIf(toFloat64(sumIf(visits,mnum=2)),0), 0),
    round(coalesce(toFloat64(sumIf(shaa_total,mnum=3)),0)/nullIf(toFloat64(sumIf(visits,mnum=3)),0), 0),
    round(coalesce(toFloat64(sumIf(shaa_total,mnum=4)),0)/nullIf(toFloat64(sumIf(visits,mnum=4)),0), 0),
    round(coalesce(toFloat64(sumIf(shaa_total,mnum=5)),0)/nullIf(toFloat64(sumIf(visits,mnum=5)),0), 0),
    round(coalesce(toFloat64(sumIf(shaa_total,mnum=6)),0)/nullIf(toFloat64(sumIf(visits,mnum=6)),0), 0),
    round(coalesce(toFloat64(sumIf(shaa_total,mnum=7)),0)/nullIf(toFloat64(sumIf(visits,mnum=7)),0), 0),
    round(coalesce(toFloat64(sumIf(shaa_total,mnum=8)),0)/nullIf(toFloat64(sumIf(visits,mnum=8)),0), 0),
    round(coalesce(toFloat64(sumIf(shaa_total,mnum=9)),0)/nullIf(toFloat64(sumIf(visits,mnum=9)),0), 0),
    round(coalesce(toFloat64(sumIf(shaa_total,mnum=10)),0)/nullIf(toFloat64(sumIf(visits,mnum=10)),0), 0),
    round(coalesce(toFloat64(sumIf(shaa_total,mnum=11)),0)/nullIf(toFloat64(sumIf(visits,mnum=11)),0), 0),
    round(coalesce(toFloat64(sumIf(shaa_total,mnum=12)),0)/nullIf(toFloat64(sumIf(visits,mnum=12)),0), 0),
    round(coalesce(toFloat64(sum(shaa_total)),0)/nullIf(toFloat64(sum(visits)),0), 0)
FROM monthly
UNION ALL
SELECT 12 AS rn, 'ФОТ ШАА, % от выручки' AS "Метрика",
    round(coalesce(toFloat64(sumIf(shaa_total,mnum=1)),0)/nullIf(toFloat64(sumIf(revenue,mnum=1)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(shaa_total,mnum=2)),0)/nullIf(toFloat64(sumIf(revenue,mnum=2)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(shaa_total,mnum=3)),0)/nullIf(toFloat64(sumIf(revenue,mnum=3)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(shaa_total,mnum=4)),0)/nullIf(toFloat64(sumIf(revenue,mnum=4)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(shaa_total,mnum=5)),0)/nullIf(toFloat64(sumIf(revenue,mnum=5)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(shaa_total,mnum=6)),0)/nullIf(toFloat64(sumIf(revenue,mnum=6)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(shaa_total,mnum=7)),0)/nullIf(toFloat64(sumIf(revenue,mnum=7)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(shaa_total,mnum=8)),0)/nullIf(toFloat64(sumIf(revenue,mnum=8)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(shaa_total,mnum=9)),0)/nullIf(toFloat64(sumIf(revenue,mnum=9)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(shaa_total,mnum=10)),0)/nullIf(toFloat64(sumIf(revenue,mnum=10)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(shaa_total,mnum=11)),0)/nullIf(toFloat64(sumIf(revenue,mnum=11)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(shaa_total,mnum=12)),0)/nullIf(toFloat64(sumIf(revenue,mnum=12)),0)*100, 1),
    round(coalesce(toFloat64(sum(shaa_total)),0)/nullIf(toFloat64(sum(revenue)),0)*100, 1)
FROM monthly
UNION ALL
SELECT 13 AS rn, 'Взносы и НДФЛ Психиатров | Визиты' AS "Метрика",
    round(-coalesce(toFloat64(sumIf(taxes_psy,mnum=1)),0)/nullIf(toFloat64(sumIf(visits,mnum=1)),0), 0),
    round(-coalesce(toFloat64(sumIf(taxes_psy,mnum=2)),0)/nullIf(toFloat64(sumIf(visits,mnum=2)),0), 0),
    round(-coalesce(toFloat64(sumIf(taxes_psy,mnum=3)),0)/nullIf(toFloat64(sumIf(visits,mnum=3)),0), 0),
    round(-coalesce(toFloat64(sumIf(taxes_psy,mnum=4)),0)/nullIf(toFloat64(sumIf(visits,mnum=4)),0), 0),
    round(-coalesce(toFloat64(sumIf(taxes_psy,mnum=5)),0)/nullIf(toFloat64(sumIf(visits,mnum=5)),0), 0),
    round(-coalesce(toFloat64(sumIf(taxes_psy,mnum=6)),0)/nullIf(toFloat64(sumIf(visits,mnum=6)),0), 0),
    round(-coalesce(toFloat64(sumIf(taxes_psy,mnum=7)),0)/nullIf(toFloat64(sumIf(visits,mnum=7)),0), 0),
    round(-coalesce(toFloat64(sumIf(taxes_psy,mnum=8)),0)/nullIf(toFloat64(sumIf(visits,mnum=8)),0), 0),
    round(-coalesce(toFloat64(sumIf(taxes_psy,mnum=9)),0)/nullIf(toFloat64(sumIf(visits,mnum=9)),0), 0),
    round(-coalesce(toFloat64(sumIf(taxes_psy,mnum=10)),0)/nullIf(toFloat64(sumIf(visits,mnum=10)),0), 0),
    round(-coalesce(toFloat64(sumIf(taxes_psy,mnum=11)),0)/nullIf(toFloat64(sumIf(visits,mnum=11)),0), 0),
    round(-coalesce(toFloat64(sumIf(taxes_psy,mnum=12)),0)/nullIf(toFloat64(sumIf(visits,mnum=12)),0), 0),
    round(-coalesce(toFloat64(sum(taxes_psy)),0)/nullIf(toFloat64(sum(visits)),0), 0)
FROM monthly
UNION ALL
SELECT 14 AS rn, 'Взносы и НДФЛ Психиатров, % от выручки' AS "Метрика",
    round(-coalesce(toFloat64(sumIf(taxes_psy,mnum=1)),0)/nullIf(toFloat64(sumIf(revenue,mnum=1)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(taxes_psy,mnum=2)),0)/nullIf(toFloat64(sumIf(revenue,mnum=2)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(taxes_psy,mnum=3)),0)/nullIf(toFloat64(sumIf(revenue,mnum=3)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(taxes_psy,mnum=4)),0)/nullIf(toFloat64(sumIf(revenue,mnum=4)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(taxes_psy,mnum=5)),0)/nullIf(toFloat64(sumIf(revenue,mnum=5)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(taxes_psy,mnum=6)),0)/nullIf(toFloat64(sumIf(revenue,mnum=6)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(taxes_psy,mnum=7)),0)/nullIf(toFloat64(sumIf(revenue,mnum=7)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(taxes_psy,mnum=8)),0)/nullIf(toFloat64(sumIf(revenue,mnum=8)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(taxes_psy,mnum=9)),0)/nullIf(toFloat64(sumIf(revenue,mnum=9)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(taxes_psy,mnum=10)),0)/nullIf(toFloat64(sumIf(revenue,mnum=10)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(taxes_psy,mnum=11)),0)/nullIf(toFloat64(sumIf(revenue,mnum=11)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(taxes_psy,mnum=12)),0)/nullIf(toFloat64(sumIf(revenue,mnum=12)),0)*100, 1),
    round(-coalesce(toFloat64(sum(taxes_psy)),0)/nullIf(toFloat64(sum(revenue)),0)*100, 1)
FROM monthly
UNION ALL
SELECT 15 AS rn, 'Взносы и НДФЛ Психологов | Визиты' AS "Метрика",
    round(-coalesce(toFloat64(sumIf(taxes_pso,mnum=1)),0)/nullIf(toFloat64(sumIf(visits,mnum=1)),0), 0),
    round(-coalesce(toFloat64(sumIf(taxes_pso,mnum=2)),0)/nullIf(toFloat64(sumIf(visits,mnum=2)),0), 0),
    round(-coalesce(toFloat64(sumIf(taxes_pso,mnum=3)),0)/nullIf(toFloat64(sumIf(visits,mnum=3)),0), 0),
    round(-coalesce(toFloat64(sumIf(taxes_pso,mnum=4)),0)/nullIf(toFloat64(sumIf(visits,mnum=4)),0), 0),
    round(-coalesce(toFloat64(sumIf(taxes_pso,mnum=5)),0)/nullIf(toFloat64(sumIf(visits,mnum=5)),0), 0),
    round(-coalesce(toFloat64(sumIf(taxes_pso,mnum=6)),0)/nullIf(toFloat64(sumIf(visits,mnum=6)),0), 0),
    round(-coalesce(toFloat64(sumIf(taxes_pso,mnum=7)),0)/nullIf(toFloat64(sumIf(visits,mnum=7)),0), 0),
    round(-coalesce(toFloat64(sumIf(taxes_pso,mnum=8)),0)/nullIf(toFloat64(sumIf(visits,mnum=8)),0), 0),
    round(-coalesce(toFloat64(sumIf(taxes_pso,mnum=9)),0)/nullIf(toFloat64(sumIf(visits,mnum=9)),0), 0),
    round(-coalesce(toFloat64(sumIf(taxes_pso,mnum=10)),0)/nullIf(toFloat64(sumIf(visits,mnum=10)),0), 0),
    round(-coalesce(toFloat64(sumIf(taxes_pso,mnum=11)),0)/nullIf(toFloat64(sumIf(visits,mnum=11)),0), 0),
    round(-coalesce(toFloat64(sumIf(taxes_pso,mnum=12)),0)/nullIf(toFloat64(sumIf(visits,mnum=12)),0), 0),
    round(-coalesce(toFloat64(sum(taxes_pso)),0)/nullIf(toFloat64(sum(visits)),0), 0)
FROM monthly
UNION ALL
SELECT 16 AS rn, 'Взносы и НДФЛ Психологов, % от выручки' AS "Метрика",
    round(-coalesce(toFloat64(sumIf(taxes_pso,mnum=1)),0)/nullIf(toFloat64(sumIf(revenue,mnum=1)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(taxes_pso,mnum=2)),0)/nullIf(toFloat64(sumIf(revenue,mnum=2)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(taxes_pso,mnum=3)),0)/nullIf(toFloat64(sumIf(revenue,mnum=3)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(taxes_pso,mnum=4)),0)/nullIf(toFloat64(sumIf(revenue,mnum=4)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(taxes_pso,mnum=5)),0)/nullIf(toFloat64(sumIf(revenue,mnum=5)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(taxes_pso,mnum=6)),0)/nullIf(toFloat64(sumIf(revenue,mnum=6)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(taxes_pso,mnum=7)),0)/nullIf(toFloat64(sumIf(revenue,mnum=7)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(taxes_pso,mnum=8)),0)/nullIf(toFloat64(sumIf(revenue,mnum=8)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(taxes_pso,mnum=9)),0)/nullIf(toFloat64(sumIf(revenue,mnum=9)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(taxes_pso,mnum=10)),0)/nullIf(toFloat64(sumIf(revenue,mnum=10)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(taxes_pso,mnum=11)),0)/nullIf(toFloat64(sumIf(revenue,mnum=11)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(taxes_pso,mnum=12)),0)/nullIf(toFloat64(sumIf(revenue,mnum=12)),0)*100, 1),
    round(-coalesce(toFloat64(sum(taxes_pso)),0)/nullIf(toFloat64(sum(revenue)),0)*100, 1)
FROM monthly
UNION ALL
SELECT 17 AS rn, 'Прибыль после Врачей | Визиты' AS "Метрика",
    round((toFloat64(sumIf(revenue,mnum=1))-coalesce(toFloat64(sumIf(fot_own,mnum=1)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=1)),0))/nullIf(toFloat64(sumIf(visits,mnum=1)),0), 0),
    round((toFloat64(sumIf(revenue,mnum=2))-coalesce(toFloat64(sumIf(fot_own,mnum=2)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=2)),0))/nullIf(toFloat64(sumIf(visits,mnum=2)),0), 0),
    round((toFloat64(sumIf(revenue,mnum=3))-coalesce(toFloat64(sumIf(fot_own,mnum=3)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=3)),0))/nullIf(toFloat64(sumIf(visits,mnum=3)),0), 0),
    round((toFloat64(sumIf(revenue,mnum=4))-coalesce(toFloat64(sumIf(fot_own,mnum=4)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=4)),0))/nullIf(toFloat64(sumIf(visits,mnum=4)),0), 0),
    round((toFloat64(sumIf(revenue,mnum=5))-coalesce(toFloat64(sumIf(fot_own,mnum=5)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=5)),0))/nullIf(toFloat64(sumIf(visits,mnum=5)),0), 0),
    round((toFloat64(sumIf(revenue,mnum=6))-coalesce(toFloat64(sumIf(fot_own,mnum=6)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=6)),0))/nullIf(toFloat64(sumIf(visits,mnum=6)),0), 0),
    round((toFloat64(sumIf(revenue,mnum=7))-coalesce(toFloat64(sumIf(fot_own,mnum=7)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=7)),0))/nullIf(toFloat64(sumIf(visits,mnum=7)),0), 0),
    round((toFloat64(sumIf(revenue,mnum=8))-coalesce(toFloat64(sumIf(fot_own,mnum=8)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=8)),0))/nullIf(toFloat64(sumIf(visits,mnum=8)),0), 0),
    round((toFloat64(sumIf(revenue,mnum=9))-coalesce(toFloat64(sumIf(fot_own,mnum=9)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=9)),0))/nullIf(toFloat64(sumIf(visits,mnum=9)),0), 0),
    round((toFloat64(sumIf(revenue,mnum=10))-coalesce(toFloat64(sumIf(fot_own,mnum=10)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=10)),0))/nullIf(toFloat64(sumIf(visits,mnum=10)),0), 0),
    round((toFloat64(sumIf(revenue,mnum=11))-coalesce(toFloat64(sumIf(fot_own,mnum=11)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=11)),0))/nullIf(toFloat64(sumIf(visits,mnum=11)),0), 0),
    round((toFloat64(sumIf(revenue,mnum=12))-coalesce(toFloat64(sumIf(fot_own,mnum=12)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=12)),0))/nullIf(toFloat64(sumIf(visits,mnum=12)),0), 0),
    round((toFloat64(sum(revenue))-coalesce(toFloat64(sum(fot_own)),0)+coalesce(toFloat64(sum(taxes_own)),0))/nullIf(toFloat64(sum(visits)),0), 0)
FROM monthly
UNION ALL
SELECT 18 AS rn, 'Маржинальность Врачей, %' AS "Метрика",
    round((toFloat64(sumIf(revenue,mnum=1))-coalesce(toFloat64(sumIf(fot_own,mnum=1)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=1)),0))/nullIf(toFloat64(sumIf(revenue,mnum=1)),0)*100, 1),
    round((toFloat64(sumIf(revenue,mnum=2))-coalesce(toFloat64(sumIf(fot_own,mnum=2)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=2)),0))/nullIf(toFloat64(sumIf(revenue,mnum=2)),0)*100, 1),
    round((toFloat64(sumIf(revenue,mnum=3))-coalesce(toFloat64(sumIf(fot_own,mnum=3)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=3)),0))/nullIf(toFloat64(sumIf(revenue,mnum=3)),0)*100, 1),
    round((toFloat64(sumIf(revenue,mnum=4))-coalesce(toFloat64(sumIf(fot_own,mnum=4)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=4)),0))/nullIf(toFloat64(sumIf(revenue,mnum=4)),0)*100, 1),
    round((toFloat64(sumIf(revenue,mnum=5))-coalesce(toFloat64(sumIf(fot_own,mnum=5)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=5)),0))/nullIf(toFloat64(sumIf(revenue,mnum=5)),0)*100, 1),
    round((toFloat64(sumIf(revenue,mnum=6))-coalesce(toFloat64(sumIf(fot_own,mnum=6)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=6)),0))/nullIf(toFloat64(sumIf(revenue,mnum=6)),0)*100, 1),
    round((toFloat64(sumIf(revenue,mnum=7))-coalesce(toFloat64(sumIf(fot_own,mnum=7)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=7)),0))/nullIf(toFloat64(sumIf(revenue,mnum=7)),0)*100, 1),
    round((toFloat64(sumIf(revenue,mnum=8))-coalesce(toFloat64(sumIf(fot_own,mnum=8)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=8)),0))/nullIf(toFloat64(sumIf(revenue,mnum=8)),0)*100, 1),
    round((toFloat64(sumIf(revenue,mnum=9))-coalesce(toFloat64(sumIf(fot_own,mnum=9)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=9)),0))/nullIf(toFloat64(sumIf(revenue,mnum=9)),0)*100, 1),
    round((toFloat64(sumIf(revenue,mnum=10))-coalesce(toFloat64(sumIf(fot_own,mnum=10)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=10)),0))/nullIf(toFloat64(sumIf(revenue,mnum=10)),0)*100, 1),
    round((toFloat64(sumIf(revenue,mnum=11))-coalesce(toFloat64(sumIf(fot_own,mnum=11)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=11)),0))/nullIf(toFloat64(sumIf(revenue,mnum=11)),0)*100, 1),
    round((toFloat64(sumIf(revenue,mnum=12))-coalesce(toFloat64(sumIf(fot_own,mnum=12)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=12)),0))/nullIf(toFloat64(sumIf(revenue,mnum=12)),0)*100, 1),
    round((toFloat64(sum(revenue))-coalesce(toFloat64(sum(fot_own)),0)+coalesce(toFloat64(sum(taxes_own)),0))/nullIf(toFloat64(sum(revenue)),0)*100, 1)
FROM monthly
UNION ALL
SELECT 19 AS rn, '' AS "Метрика",
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL
FROM monthly LIMIT 1
UNION ALL
SELECT 20 AS rn, 'ФОТ Администраторы | Визиты' AS "Метрика",
    round(coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=1)),0)/nullIf(toFloat64(sumIf(visits,mnum=1)),0), 0),
    round(coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=2)),0)/nullIf(toFloat64(sumIf(visits,mnum=2)),0), 0),
    round(coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=3)),0)/nullIf(toFloat64(sumIf(visits,mnum=3)),0), 0),
    round(coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=4)),0)/nullIf(toFloat64(sumIf(visits,mnum=4)),0), 0),
    round(coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=5)),0)/nullIf(toFloat64(sumIf(visits,mnum=5)),0), 0),
    round(coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=6)),0)/nullIf(toFloat64(sumIf(visits,mnum=6)),0), 0),
    round(coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=7)),0)/nullIf(toFloat64(sumIf(visits,mnum=7)),0), 0),
    round(coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=8)),0)/nullIf(toFloat64(sumIf(visits,mnum=8)),0), 0),
    round(coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=9)),0)/nullIf(toFloat64(sumIf(visits,mnum=9)),0), 0),
    round(coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=10)),0)/nullIf(toFloat64(sumIf(visits,mnum=10)),0), 0),
    round(coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=11)),0)/nullIf(toFloat64(sumIf(visits,mnum=11)),0), 0),
    round(coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=12)),0)/nullIf(toFloat64(sumIf(visits,mnum=12)),0), 0),
    round(coalesce(toFloat64(sum(adm_fot_attributed)),0)/nullIf(toFloat64(sum(visits)),0), 0)
FROM monthly
UNION ALL
SELECT 21 AS rn, 'ФОТ Администраторы, % от выручки' AS "Метрика",
    round(coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=1)),0)/nullIf(toFloat64(sumIf(revenue,mnum=1)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=2)),0)/nullIf(toFloat64(sumIf(revenue,mnum=2)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=3)),0)/nullIf(toFloat64(sumIf(revenue,mnum=3)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=4)),0)/nullIf(toFloat64(sumIf(revenue,mnum=4)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=5)),0)/nullIf(toFloat64(sumIf(revenue,mnum=5)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=6)),0)/nullIf(toFloat64(sumIf(revenue,mnum=6)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=7)),0)/nullIf(toFloat64(sumIf(revenue,mnum=7)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=8)),0)/nullIf(toFloat64(sumIf(revenue,mnum=8)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=9)),0)/nullIf(toFloat64(sumIf(revenue,mnum=9)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=10)),0)/nullIf(toFloat64(sumIf(revenue,mnum=10)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=11)),0)/nullIf(toFloat64(sumIf(revenue,mnum=11)),0)*100, 1),
    round(coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=12)),0)/nullIf(toFloat64(sumIf(revenue,mnum=12)),0)*100, 1),
    round(coalesce(toFloat64(sum(adm_fot_attributed)),0)/nullIf(toFloat64(sum(revenue)),0)*100, 1)
FROM monthly
UNION ALL
SELECT 22 AS rn, 'Взносы и НДФЛ Админов | Визиты' AS "Метрика",
    round(-coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=1)),0)/nullIf(toFloat64(sumIf(visits,mnum=1)),0), 0),
    round(-coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=2)),0)/nullIf(toFloat64(sumIf(visits,mnum=2)),0), 0),
    round(-coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=3)),0)/nullIf(toFloat64(sumIf(visits,mnum=3)),0), 0),
    round(-coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=4)),0)/nullIf(toFloat64(sumIf(visits,mnum=4)),0), 0),
    round(-coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=5)),0)/nullIf(toFloat64(sumIf(visits,mnum=5)),0), 0),
    round(-coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=6)),0)/nullIf(toFloat64(sumIf(visits,mnum=6)),0), 0),
    round(-coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=7)),0)/nullIf(toFloat64(sumIf(visits,mnum=7)),0), 0),
    round(-coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=8)),0)/nullIf(toFloat64(sumIf(visits,mnum=8)),0), 0),
    round(-coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=9)),0)/nullIf(toFloat64(sumIf(visits,mnum=9)),0), 0),
    round(-coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=10)),0)/nullIf(toFloat64(sumIf(visits,mnum=10)),0), 0),
    round(-coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=11)),0)/nullIf(toFloat64(sumIf(visits,mnum=11)),0), 0),
    round(-coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=12)),0)/nullIf(toFloat64(sumIf(visits,mnum=12)),0), 0),
    round(-coalesce(toFloat64(sum(adm_tax_attributed)),0)/nullIf(toFloat64(sum(visits)),0), 0)
FROM monthly
UNION ALL
SELECT 23 AS rn, 'Взносы и НДФЛ Админов, % от выручки' AS "Метрика",
    round(-coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=1)),0)/nullIf(toFloat64(sumIf(revenue,mnum=1)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=2)),0)/nullIf(toFloat64(sumIf(revenue,mnum=2)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=3)),0)/nullIf(toFloat64(sumIf(revenue,mnum=3)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=4)),0)/nullIf(toFloat64(sumIf(revenue,mnum=4)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=5)),0)/nullIf(toFloat64(sumIf(revenue,mnum=5)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=6)),0)/nullIf(toFloat64(sumIf(revenue,mnum=6)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=7)),0)/nullIf(toFloat64(sumIf(revenue,mnum=7)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=8)),0)/nullIf(toFloat64(sumIf(revenue,mnum=8)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=9)),0)/nullIf(toFloat64(sumIf(revenue,mnum=9)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=10)),0)/nullIf(toFloat64(sumIf(revenue,mnum=10)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=11)),0)/nullIf(toFloat64(sumIf(revenue,mnum=11)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=12)),0)/nullIf(toFloat64(sumIf(revenue,mnum=12)),0)*100, 1),
    round(-coalesce(toFloat64(sum(adm_tax_attributed)),0)/nullIf(toFloat64(sum(revenue)),0)*100, 1)
FROM monthly
UNION ALL
SELECT 24 AS rn, 'Аренда и коммуналка | Визиты' AS "Метрика",
    round(-coalesce(toFloat64(sumIf(rent_attributed,mnum=1)),0)/nullIf(toFloat64(sumIf(visits,mnum=1)),0), 0),
    round(-coalesce(toFloat64(sumIf(rent_attributed,mnum=2)),0)/nullIf(toFloat64(sumIf(visits,mnum=2)),0), 0),
    round(-coalesce(toFloat64(sumIf(rent_attributed,mnum=3)),0)/nullIf(toFloat64(sumIf(visits,mnum=3)),0), 0),
    round(-coalesce(toFloat64(sumIf(rent_attributed,mnum=4)),0)/nullIf(toFloat64(sumIf(visits,mnum=4)),0), 0),
    round(-coalesce(toFloat64(sumIf(rent_attributed,mnum=5)),0)/nullIf(toFloat64(sumIf(visits,mnum=5)),0), 0),
    round(-coalesce(toFloat64(sumIf(rent_attributed,mnum=6)),0)/nullIf(toFloat64(sumIf(visits,mnum=6)),0), 0),
    round(-coalesce(toFloat64(sumIf(rent_attributed,mnum=7)),0)/nullIf(toFloat64(sumIf(visits,mnum=7)),0), 0),
    round(-coalesce(toFloat64(sumIf(rent_attributed,mnum=8)),0)/nullIf(toFloat64(sumIf(visits,mnum=8)),0), 0),
    round(-coalesce(toFloat64(sumIf(rent_attributed,mnum=9)),0)/nullIf(toFloat64(sumIf(visits,mnum=9)),0), 0),
    round(-coalesce(toFloat64(sumIf(rent_attributed,mnum=10)),0)/nullIf(toFloat64(sumIf(visits,mnum=10)),0), 0),
    round(-coalesce(toFloat64(sumIf(rent_attributed,mnum=11)),0)/nullIf(toFloat64(sumIf(visits,mnum=11)),0), 0),
    round(-coalesce(toFloat64(sumIf(rent_attributed,mnum=12)),0)/nullIf(toFloat64(sumIf(visits,mnum=12)),0), 0),
    round(-coalesce(toFloat64(sum(rent_attributed)),0)/nullIf(toFloat64(sum(visits)),0), 0)
FROM monthly
UNION ALL
SELECT 25 AS rn, 'Аренда и коммуналка, % от выручки' AS "Метрика",
    round(-coalesce(toFloat64(sumIf(rent_attributed,mnum=1)),0)/nullIf(toFloat64(sumIf(revenue,mnum=1)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(rent_attributed,mnum=2)),0)/nullIf(toFloat64(sumIf(revenue,mnum=2)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(rent_attributed,mnum=3)),0)/nullIf(toFloat64(sumIf(revenue,mnum=3)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(rent_attributed,mnum=4)),0)/nullIf(toFloat64(sumIf(revenue,mnum=4)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(rent_attributed,mnum=5)),0)/nullIf(toFloat64(sumIf(revenue,mnum=5)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(rent_attributed,mnum=6)),0)/nullIf(toFloat64(sumIf(revenue,mnum=6)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(rent_attributed,mnum=7)),0)/nullIf(toFloat64(sumIf(revenue,mnum=7)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(rent_attributed,mnum=8)),0)/nullIf(toFloat64(sumIf(revenue,mnum=8)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(rent_attributed,mnum=9)),0)/nullIf(toFloat64(sumIf(revenue,mnum=9)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(rent_attributed,mnum=10)),0)/nullIf(toFloat64(sumIf(revenue,mnum=10)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(rent_attributed,mnum=11)),0)/nullIf(toFloat64(sumIf(revenue,mnum=11)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(rent_attributed,mnum=12)),0)/nullIf(toFloat64(sumIf(revenue,mnum=12)),0)*100, 1),
    round(-coalesce(toFloat64(sum(rent_attributed)),0)/nullIf(toFloat64(sum(revenue)),0)*100, 1)
FROM monthly
UNION ALL
SELECT 26 AS rn, 'Прибыль после Админа | Визиты' AS "Метрика",
    round((toFloat64(sumIf(revenue,mnum=1))-coalesce(toFloat64(sumIf(fot_own,mnum=1)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=1)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=1)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=1)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=1)),0))/nullIf(toFloat64(sumIf(visits,mnum=1)),0), 0),
    round((toFloat64(sumIf(revenue,mnum=2))-coalesce(toFloat64(sumIf(fot_own,mnum=2)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=2)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=2)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=2)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=2)),0))/nullIf(toFloat64(sumIf(visits,mnum=2)),0), 0),
    round((toFloat64(sumIf(revenue,mnum=3))-coalesce(toFloat64(sumIf(fot_own,mnum=3)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=3)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=3)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=3)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=3)),0))/nullIf(toFloat64(sumIf(visits,mnum=3)),0), 0),
    round((toFloat64(sumIf(revenue,mnum=4))-coalesce(toFloat64(sumIf(fot_own,mnum=4)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=4)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=4)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=4)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=4)),0))/nullIf(toFloat64(sumIf(visits,mnum=4)),0), 0),
    round((toFloat64(sumIf(revenue,mnum=5))-coalesce(toFloat64(sumIf(fot_own,mnum=5)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=5)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=5)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=5)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=5)),0))/nullIf(toFloat64(sumIf(visits,mnum=5)),0), 0),
    round((toFloat64(sumIf(revenue,mnum=6))-coalesce(toFloat64(sumIf(fot_own,mnum=6)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=6)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=6)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=6)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=6)),0))/nullIf(toFloat64(sumIf(visits,mnum=6)),0), 0),
    round((toFloat64(sumIf(revenue,mnum=7))-coalesce(toFloat64(sumIf(fot_own,mnum=7)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=7)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=7)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=7)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=7)),0))/nullIf(toFloat64(sumIf(visits,mnum=7)),0), 0),
    round((toFloat64(sumIf(revenue,mnum=8))-coalesce(toFloat64(sumIf(fot_own,mnum=8)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=8)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=8)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=8)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=8)),0))/nullIf(toFloat64(sumIf(visits,mnum=8)),0), 0),
    round((toFloat64(sumIf(revenue,mnum=9))-coalesce(toFloat64(sumIf(fot_own,mnum=9)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=9)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=9)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=9)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=9)),0))/nullIf(toFloat64(sumIf(visits,mnum=9)),0), 0),
    round((toFloat64(sumIf(revenue,mnum=10))-coalesce(toFloat64(sumIf(fot_own,mnum=10)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=10)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=10)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=10)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=10)),0))/nullIf(toFloat64(sumIf(visits,mnum=10)),0), 0),
    round((toFloat64(sumIf(revenue,mnum=11))-coalesce(toFloat64(sumIf(fot_own,mnum=11)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=11)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=11)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=11)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=11)),0))/nullIf(toFloat64(sumIf(visits,mnum=11)),0), 0),
    round((toFloat64(sumIf(revenue,mnum=12))-coalesce(toFloat64(sumIf(fot_own,mnum=12)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=12)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=12)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=12)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=12)),0))/nullIf(toFloat64(sumIf(visits,mnum=12)),0), 0),
    round((toFloat64(sum(revenue))-coalesce(toFloat64(sum(fot_own)),0)+coalesce(toFloat64(sum(taxes_own)),0)-coalesce(toFloat64(sum(adm_fot_attributed)),0)+coalesce(toFloat64(sum(adm_tax_attributed)),0)+coalesce(toFloat64(sum(rent_attributed)),0))/nullIf(toFloat64(sum(visits)),0), 0)
FROM monthly
UNION ALL
SELECT 27 AS rn, 'Маржинальность Кабинетов, %' AS "Метрика",
    round((toFloat64(sumIf(revenue,mnum=1))-coalesce(toFloat64(sumIf(fot_own,mnum=1)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=1)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=1)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=1)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=1)),0))/nullIf(toFloat64(sumIf(revenue,mnum=1)),0)*100, 1),
    round((toFloat64(sumIf(revenue,mnum=2))-coalesce(toFloat64(sumIf(fot_own,mnum=2)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=2)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=2)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=2)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=2)),0))/nullIf(toFloat64(sumIf(revenue,mnum=2)),0)*100, 1),
    round((toFloat64(sumIf(revenue,mnum=3))-coalesce(toFloat64(sumIf(fot_own,mnum=3)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=3)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=3)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=3)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=3)),0))/nullIf(toFloat64(sumIf(revenue,mnum=3)),0)*100, 1),
    round((toFloat64(sumIf(revenue,mnum=4))-coalesce(toFloat64(sumIf(fot_own,mnum=4)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=4)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=4)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=4)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=4)),0))/nullIf(toFloat64(sumIf(revenue,mnum=4)),0)*100, 1),
    round((toFloat64(sumIf(revenue,mnum=5))-coalesce(toFloat64(sumIf(fot_own,mnum=5)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=5)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=5)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=5)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=5)),0))/nullIf(toFloat64(sumIf(revenue,mnum=5)),0)*100, 1),
    round((toFloat64(sumIf(revenue,mnum=6))-coalesce(toFloat64(sumIf(fot_own,mnum=6)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=6)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=6)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=6)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=6)),0))/nullIf(toFloat64(sumIf(revenue,mnum=6)),0)*100, 1),
    round((toFloat64(sumIf(revenue,mnum=7))-coalesce(toFloat64(sumIf(fot_own,mnum=7)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=7)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=7)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=7)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=7)),0))/nullIf(toFloat64(sumIf(revenue,mnum=7)),0)*100, 1),
    round((toFloat64(sumIf(revenue,mnum=8))-coalesce(toFloat64(sumIf(fot_own,mnum=8)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=8)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=8)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=8)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=8)),0))/nullIf(toFloat64(sumIf(revenue,mnum=8)),0)*100, 1),
    round((toFloat64(sumIf(revenue,mnum=9))-coalesce(toFloat64(sumIf(fot_own,mnum=9)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=9)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=9)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=9)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=9)),0))/nullIf(toFloat64(sumIf(revenue,mnum=9)),0)*100, 1),
    round((toFloat64(sumIf(revenue,mnum=10))-coalesce(toFloat64(sumIf(fot_own,mnum=10)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=10)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=10)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=10)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=10)),0))/nullIf(toFloat64(sumIf(revenue,mnum=10)),0)*100, 1),
    round((toFloat64(sumIf(revenue,mnum=11))-coalesce(toFloat64(sumIf(fot_own,mnum=11)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=11)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=11)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=11)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=11)),0))/nullIf(toFloat64(sumIf(revenue,mnum=11)),0)*100, 1),
    round((toFloat64(sumIf(revenue,mnum=12))-coalesce(toFloat64(sumIf(fot_own,mnum=12)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=12)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=12)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=12)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=12)),0))/nullIf(toFloat64(sumIf(revenue,mnum=12)),0)*100, 1),
    round((toFloat64(sum(revenue))-coalesce(toFloat64(sum(fot_own)),0)+coalesce(toFloat64(sum(taxes_own)),0)-coalesce(toFloat64(sum(adm_fot_attributed)),0)+coalesce(toFloat64(sum(adm_tax_attributed)),0)+coalesce(toFloat64(sum(rent_attributed)),0))/nullIf(toFloat64(sum(revenue)),0)*100, 1)
FROM monthly
UNION ALL
SELECT 28 AS rn, '' AS "Метрика",
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL
FROM monthly LIMIT 1
UNION ALL
SELECT 29 AS rn, 'Маркетинг | Визиты' AS "Метрика",
    round(-coalesce(toFloat64(sumIf(mkt_attributed,mnum=1)),0)/nullIf(toFloat64(sumIf(visits,mnum=1)),0), 0),
    round(-coalesce(toFloat64(sumIf(mkt_attributed,mnum=2)),0)/nullIf(toFloat64(sumIf(visits,mnum=2)),0), 0),
    round(-coalesce(toFloat64(sumIf(mkt_attributed,mnum=3)),0)/nullIf(toFloat64(sumIf(visits,mnum=3)),0), 0),
    round(-coalesce(toFloat64(sumIf(mkt_attributed,mnum=4)),0)/nullIf(toFloat64(sumIf(visits,mnum=4)),0), 0),
    round(-coalesce(toFloat64(sumIf(mkt_attributed,mnum=5)),0)/nullIf(toFloat64(sumIf(visits,mnum=5)),0), 0),
    round(-coalesce(toFloat64(sumIf(mkt_attributed,mnum=6)),0)/nullIf(toFloat64(sumIf(visits,mnum=6)),0), 0),
    round(-coalesce(toFloat64(sumIf(mkt_attributed,mnum=7)),0)/nullIf(toFloat64(sumIf(visits,mnum=7)),0), 0),
    round(-coalesce(toFloat64(sumIf(mkt_attributed,mnum=8)),0)/nullIf(toFloat64(sumIf(visits,mnum=8)),0), 0),
    round(-coalesce(toFloat64(sumIf(mkt_attributed,mnum=9)),0)/nullIf(toFloat64(sumIf(visits,mnum=9)),0), 0),
    round(-coalesce(toFloat64(sumIf(mkt_attributed,mnum=10)),0)/nullIf(toFloat64(sumIf(visits,mnum=10)),0), 0),
    round(-coalesce(toFloat64(sumIf(mkt_attributed,mnum=11)),0)/nullIf(toFloat64(sumIf(visits,mnum=11)),0), 0),
    round(-coalesce(toFloat64(sumIf(mkt_attributed,mnum=12)),0)/nullIf(toFloat64(sumIf(visits,mnum=12)),0), 0),
    round(-coalesce(toFloat64(sum(mkt_attributed)),0)/nullIf(toFloat64(sum(visits)),0), 0)
FROM monthly
UNION ALL
SELECT 30 AS rn, 'Маркетинг, % от выручки' AS "Метрика",
    round(-coalesce(toFloat64(sumIf(mkt_attributed,mnum=1)),0)/nullIf(toFloat64(sumIf(revenue,mnum=1)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(mkt_attributed,mnum=2)),0)/nullIf(toFloat64(sumIf(revenue,mnum=2)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(mkt_attributed,mnum=3)),0)/nullIf(toFloat64(sumIf(revenue,mnum=3)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(mkt_attributed,mnum=4)),0)/nullIf(toFloat64(sumIf(revenue,mnum=4)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(mkt_attributed,mnum=5)),0)/nullIf(toFloat64(sumIf(revenue,mnum=5)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(mkt_attributed,mnum=6)),0)/nullIf(toFloat64(sumIf(revenue,mnum=6)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(mkt_attributed,mnum=7)),0)/nullIf(toFloat64(sumIf(revenue,mnum=7)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(mkt_attributed,mnum=8)),0)/nullIf(toFloat64(sumIf(revenue,mnum=8)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(mkt_attributed,mnum=9)),0)/nullIf(toFloat64(sumIf(revenue,mnum=9)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(mkt_attributed,mnum=10)),0)/nullIf(toFloat64(sumIf(revenue,mnum=10)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(mkt_attributed,mnum=11)),0)/nullIf(toFloat64(sumIf(revenue,mnum=11)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(mkt_attributed,mnum=12)),0)/nullIf(toFloat64(sumIf(revenue,mnum=12)),0)*100, 1),
    round(-coalesce(toFloat64(sum(mkt_attributed)),0)/nullIf(toFloat64(sum(revenue)),0)*100, 1)
FROM monthly
UNION ALL
SELECT 31 AS rn, 'Управление | Визиты' AS "Метрика",
    round(-coalesce(toFloat64(sumIf(upr_attributed,mnum=1)),0)/nullIf(toFloat64(sumIf(visits,mnum=1)),0), 0),
    round(-coalesce(toFloat64(sumIf(upr_attributed,mnum=2)),0)/nullIf(toFloat64(sumIf(visits,mnum=2)),0), 0),
    round(-coalesce(toFloat64(sumIf(upr_attributed,mnum=3)),0)/nullIf(toFloat64(sumIf(visits,mnum=3)),0), 0),
    round(-coalesce(toFloat64(sumIf(upr_attributed,mnum=4)),0)/nullIf(toFloat64(sumIf(visits,mnum=4)),0), 0),
    round(-coalesce(toFloat64(sumIf(upr_attributed,mnum=5)),0)/nullIf(toFloat64(sumIf(visits,mnum=5)),0), 0),
    round(-coalesce(toFloat64(sumIf(upr_attributed,mnum=6)),0)/nullIf(toFloat64(sumIf(visits,mnum=6)),0), 0),
    round(-coalesce(toFloat64(sumIf(upr_attributed,mnum=7)),0)/nullIf(toFloat64(sumIf(visits,mnum=7)),0), 0),
    round(-coalesce(toFloat64(sumIf(upr_attributed,mnum=8)),0)/nullIf(toFloat64(sumIf(visits,mnum=8)),0), 0),
    round(-coalesce(toFloat64(sumIf(upr_attributed,mnum=9)),0)/nullIf(toFloat64(sumIf(visits,mnum=9)),0), 0),
    round(-coalesce(toFloat64(sumIf(upr_attributed,mnum=10)),0)/nullIf(toFloat64(sumIf(visits,mnum=10)),0), 0),
    round(-coalesce(toFloat64(sumIf(upr_attributed,mnum=11)),0)/nullIf(toFloat64(sumIf(visits,mnum=11)),0), 0),
    round(-coalesce(toFloat64(sumIf(upr_attributed,mnum=12)),0)/nullIf(toFloat64(sumIf(visits,mnum=12)),0), 0),
    round(-coalesce(toFloat64(sum(upr_attributed)),0)/nullIf(toFloat64(sum(visits)),0), 0)
FROM monthly
UNION ALL
SELECT 32 AS rn, 'Управление, % от выручки' AS "Метрика",
    round(-coalesce(toFloat64(sumIf(upr_attributed,mnum=1)),0)/nullIf(toFloat64(sumIf(revenue,mnum=1)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(upr_attributed,mnum=2)),0)/nullIf(toFloat64(sumIf(revenue,mnum=2)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(upr_attributed,mnum=3)),0)/nullIf(toFloat64(sumIf(revenue,mnum=3)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(upr_attributed,mnum=4)),0)/nullIf(toFloat64(sumIf(revenue,mnum=4)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(upr_attributed,mnum=5)),0)/nullIf(toFloat64(sumIf(revenue,mnum=5)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(upr_attributed,mnum=6)),0)/nullIf(toFloat64(sumIf(revenue,mnum=6)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(upr_attributed,mnum=7)),0)/nullIf(toFloat64(sumIf(revenue,mnum=7)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(upr_attributed,mnum=8)),0)/nullIf(toFloat64(sumIf(revenue,mnum=8)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(upr_attributed,mnum=9)),0)/nullIf(toFloat64(sumIf(revenue,mnum=9)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(upr_attributed,mnum=10)),0)/nullIf(toFloat64(sumIf(revenue,mnum=10)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(upr_attributed,mnum=11)),0)/nullIf(toFloat64(sumIf(revenue,mnum=11)),0)*100, 1),
    round(-coalesce(toFloat64(sumIf(upr_attributed,mnum=12)),0)/nullIf(toFloat64(sumIf(revenue,mnum=12)),0)*100, 1),
    round(-coalesce(toFloat64(sum(upr_attributed)),0)/nullIf(toFloat64(sum(revenue)),0)*100, 1)
FROM monthly
UNION ALL
SELECT 33 AS rn, 'EBITDA | Визиты' AS "Метрика",
    round((toFloat64(sumIf(revenue,mnum=1))-coalesce(toFloat64(sumIf(fot_own,mnum=1)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=1)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=1)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=1)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=1)),0)+coalesce(toFloat64(sumIf(upr_attributed,mnum=1)),0)+coalesce(toFloat64(sumIf(mkt_attributed,mnum=1)),0))/nullIf(toFloat64(sumIf(visits,mnum=1)),0), 0),
    round((toFloat64(sumIf(revenue,mnum=2))-coalesce(toFloat64(sumIf(fot_own,mnum=2)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=2)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=2)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=2)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=2)),0)+coalesce(toFloat64(sumIf(upr_attributed,mnum=2)),0)+coalesce(toFloat64(sumIf(mkt_attributed,mnum=2)),0))/nullIf(toFloat64(sumIf(visits,mnum=2)),0), 0),
    round((toFloat64(sumIf(revenue,mnum=3))-coalesce(toFloat64(sumIf(fot_own,mnum=3)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=3)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=3)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=3)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=3)),0)+coalesce(toFloat64(sumIf(upr_attributed,mnum=3)),0)+coalesce(toFloat64(sumIf(mkt_attributed,mnum=3)),0))/nullIf(toFloat64(sumIf(visits,mnum=3)),0), 0),
    round((toFloat64(sumIf(revenue,mnum=4))-coalesce(toFloat64(sumIf(fot_own,mnum=4)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=4)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=4)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=4)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=4)),0)+coalesce(toFloat64(sumIf(upr_attributed,mnum=4)),0)+coalesce(toFloat64(sumIf(mkt_attributed,mnum=4)),0))/nullIf(toFloat64(sumIf(visits,mnum=4)),0), 0),
    round((toFloat64(sumIf(revenue,mnum=5))-coalesce(toFloat64(sumIf(fot_own,mnum=5)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=5)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=5)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=5)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=5)),0)+coalesce(toFloat64(sumIf(upr_attributed,mnum=5)),0)+coalesce(toFloat64(sumIf(mkt_attributed,mnum=5)),0))/nullIf(toFloat64(sumIf(visits,mnum=5)),0), 0),
    round((toFloat64(sumIf(revenue,mnum=6))-coalesce(toFloat64(sumIf(fot_own,mnum=6)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=6)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=6)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=6)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=6)),0)+coalesce(toFloat64(sumIf(upr_attributed,mnum=6)),0)+coalesce(toFloat64(sumIf(mkt_attributed,mnum=6)),0))/nullIf(toFloat64(sumIf(visits,mnum=6)),0), 0),
    round((toFloat64(sumIf(revenue,mnum=7))-coalesce(toFloat64(sumIf(fot_own,mnum=7)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=7)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=7)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=7)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=7)),0)+coalesce(toFloat64(sumIf(upr_attributed,mnum=7)),0)+coalesce(toFloat64(sumIf(mkt_attributed,mnum=7)),0))/nullIf(toFloat64(sumIf(visits,mnum=7)),0), 0),
    round((toFloat64(sumIf(revenue,mnum=8))-coalesce(toFloat64(sumIf(fot_own,mnum=8)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=8)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=8)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=8)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=8)),0)+coalesce(toFloat64(sumIf(upr_attributed,mnum=8)),0)+coalesce(toFloat64(sumIf(mkt_attributed,mnum=8)),0))/nullIf(toFloat64(sumIf(visits,mnum=8)),0), 0),
    round((toFloat64(sumIf(revenue,mnum=9))-coalesce(toFloat64(sumIf(fot_own,mnum=9)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=9)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=9)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=9)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=9)),0)+coalesce(toFloat64(sumIf(upr_attributed,mnum=9)),0)+coalesce(toFloat64(sumIf(mkt_attributed,mnum=9)),0))/nullIf(toFloat64(sumIf(visits,mnum=9)),0), 0),
    round((toFloat64(sumIf(revenue,mnum=10))-coalesce(toFloat64(sumIf(fot_own,mnum=10)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=10)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=10)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=10)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=10)),0)+coalesce(toFloat64(sumIf(upr_attributed,mnum=10)),0)+coalesce(toFloat64(sumIf(mkt_attributed,mnum=10)),0))/nullIf(toFloat64(sumIf(visits,mnum=10)),0), 0),
    round((toFloat64(sumIf(revenue,mnum=11))-coalesce(toFloat64(sumIf(fot_own,mnum=11)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=11)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=11)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=11)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=11)),0)+coalesce(toFloat64(sumIf(upr_attributed,mnum=11)),0)+coalesce(toFloat64(sumIf(mkt_attributed,mnum=11)),0))/nullIf(toFloat64(sumIf(visits,mnum=11)),0), 0),
    round((toFloat64(sumIf(revenue,mnum=12))-coalesce(toFloat64(sumIf(fot_own,mnum=12)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=12)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=12)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=12)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=12)),0)+coalesce(toFloat64(sumIf(upr_attributed,mnum=12)),0)+coalesce(toFloat64(sumIf(mkt_attributed,mnum=12)),0))/nullIf(toFloat64(sumIf(visits,mnum=12)),0), 0),
    round((toFloat64(sum(revenue))-coalesce(toFloat64(sum(fot_own)),0)+coalesce(toFloat64(sum(taxes_own)),0)-coalesce(toFloat64(sum(adm_fot_attributed)),0)+coalesce(toFloat64(sum(adm_tax_attributed)),0)+coalesce(toFloat64(sum(rent_attributed)),0)+coalesce(toFloat64(sum(upr_attributed)),0)+coalesce(toFloat64(sum(mkt_attributed)),0))/nullIf(toFloat64(sum(visits)),0), 0)
FROM monthly
UNION ALL
SELECT 34 AS rn, 'Маржинальность EBITDA, %' AS "Метрика",
    round((toFloat64(sumIf(revenue,mnum=1))-coalesce(toFloat64(sumIf(fot_own,mnum=1)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=1)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=1)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=1)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=1)),0)+coalesce(toFloat64(sumIf(upr_attributed,mnum=1)),0)+coalesce(toFloat64(sumIf(mkt_attributed,mnum=1)),0))/nullIf(toFloat64(sumIf(revenue,mnum=1)),0)*100, 1),
    round((toFloat64(sumIf(revenue,mnum=2))-coalesce(toFloat64(sumIf(fot_own,mnum=2)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=2)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=2)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=2)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=2)),0)+coalesce(toFloat64(sumIf(upr_attributed,mnum=2)),0)+coalesce(toFloat64(sumIf(mkt_attributed,mnum=2)),0))/nullIf(toFloat64(sumIf(revenue,mnum=2)),0)*100, 1),
    round((toFloat64(sumIf(revenue,mnum=3))-coalesce(toFloat64(sumIf(fot_own,mnum=3)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=3)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=3)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=3)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=3)),0)+coalesce(toFloat64(sumIf(upr_attributed,mnum=3)),0)+coalesce(toFloat64(sumIf(mkt_attributed,mnum=3)),0))/nullIf(toFloat64(sumIf(revenue,mnum=3)),0)*100, 1),
    round((toFloat64(sumIf(revenue,mnum=4))-coalesce(toFloat64(sumIf(fot_own,mnum=4)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=4)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=4)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=4)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=4)),0)+coalesce(toFloat64(sumIf(upr_attributed,mnum=4)),0)+coalesce(toFloat64(sumIf(mkt_attributed,mnum=4)),0))/nullIf(toFloat64(sumIf(revenue,mnum=4)),0)*100, 1),
    round((toFloat64(sumIf(revenue,mnum=5))-coalesce(toFloat64(sumIf(fot_own,mnum=5)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=5)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=5)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=5)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=5)),0)+coalesce(toFloat64(sumIf(upr_attributed,mnum=5)),0)+coalesce(toFloat64(sumIf(mkt_attributed,mnum=5)),0))/nullIf(toFloat64(sumIf(revenue,mnum=5)),0)*100, 1),
    round((toFloat64(sumIf(revenue,mnum=6))-coalesce(toFloat64(sumIf(fot_own,mnum=6)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=6)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=6)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=6)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=6)),0)+coalesce(toFloat64(sumIf(upr_attributed,mnum=6)),0)+coalesce(toFloat64(sumIf(mkt_attributed,mnum=6)),0))/nullIf(toFloat64(sumIf(revenue,mnum=6)),0)*100, 1),
    round((toFloat64(sumIf(revenue,mnum=7))-coalesce(toFloat64(sumIf(fot_own,mnum=7)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=7)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=7)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=7)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=7)),0)+coalesce(toFloat64(sumIf(upr_attributed,mnum=7)),0)+coalesce(toFloat64(sumIf(mkt_attributed,mnum=7)),0))/nullIf(toFloat64(sumIf(revenue,mnum=7)),0)*100, 1),
    round((toFloat64(sumIf(revenue,mnum=8))-coalesce(toFloat64(sumIf(fot_own,mnum=8)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=8)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=8)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=8)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=8)),0)+coalesce(toFloat64(sumIf(upr_attributed,mnum=8)),0)+coalesce(toFloat64(sumIf(mkt_attributed,mnum=8)),0))/nullIf(toFloat64(sumIf(revenue,mnum=8)),0)*100, 1),
    round((toFloat64(sumIf(revenue,mnum=9))-coalesce(toFloat64(sumIf(fot_own,mnum=9)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=9)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=9)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=9)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=9)),0)+coalesce(toFloat64(sumIf(upr_attributed,mnum=9)),0)+coalesce(toFloat64(sumIf(mkt_attributed,mnum=9)),0))/nullIf(toFloat64(sumIf(revenue,mnum=9)),0)*100, 1),
    round((toFloat64(sumIf(revenue,mnum=10))-coalesce(toFloat64(sumIf(fot_own,mnum=10)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=10)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=10)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=10)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=10)),0)+coalesce(toFloat64(sumIf(upr_attributed,mnum=10)),0)+coalesce(toFloat64(sumIf(mkt_attributed,mnum=10)),0))/nullIf(toFloat64(sumIf(revenue,mnum=10)),0)*100, 1),
    round((toFloat64(sumIf(revenue,mnum=11))-coalesce(toFloat64(sumIf(fot_own,mnum=11)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=11)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=11)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=11)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=11)),0)+coalesce(toFloat64(sumIf(upr_attributed,mnum=11)),0)+coalesce(toFloat64(sumIf(mkt_attributed,mnum=11)),0))/nullIf(toFloat64(sumIf(revenue,mnum=11)),0)*100, 1),
    round((toFloat64(sumIf(revenue,mnum=12))-coalesce(toFloat64(sumIf(fot_own,mnum=12)),0)+coalesce(toFloat64(sumIf(taxes_own,mnum=12)),0)-coalesce(toFloat64(sumIf(adm_fot_attributed,mnum=12)),0)+coalesce(toFloat64(sumIf(adm_tax_attributed,mnum=12)),0)+coalesce(toFloat64(sumIf(rent_attributed,mnum=12)),0)+coalesce(toFloat64(sumIf(upr_attributed,mnum=12)),0)+coalesce(toFloat64(sumIf(mkt_attributed,mnum=12)),0))/nullIf(toFloat64(sumIf(revenue,mnum=12)),0)*100, 1),
    round((toFloat64(sum(revenue))-coalesce(toFloat64(sum(fot_own)),0)+coalesce(toFloat64(sum(taxes_own)),0)-coalesce(toFloat64(sum(adm_fot_attributed)),0)+coalesce(toFloat64(sum(adm_tax_attributed)),0)+coalesce(toFloat64(sum(rent_attributed)),0)+coalesce(toFloat64(sum(upr_attributed)),0)+coalesce(toFloat64(sum(mkt_attributed)),0))/nullIf(toFloat64(sum(revenue)),0)*100, 1)
FROM monthly
) ORDER BY rn

-- Без этой строки запрос может упасть с "Too many optimizations applied
-- to query plan. Current limit 10000" (TOO_MANY_QUERY_PLAN_OPTIMIZATIONS)
-- — в base используется оконная функция (count() OVER), а сверху ещё
-- 21-way UNION ALL, каждая ветка которого тянет monthly (а через неё —
-- overhead_by_month/filtered_overhead/base). Проверено на проде в
-- предыдущей версии этого файла при 26 ветках; после сокращения до 21
-- ветки запас по лимиту больше, но настройку оставляем на всякий случай.
SETTINGS query_plan_max_optimizations_to_apply = 100000
