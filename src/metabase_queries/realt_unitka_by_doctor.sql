WITH
base AS (
    SELECT
        v.card_number    AS card_number,
        v.month          AS month,
        v.role_group     AS role_group,
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
            OR ( {{doctor_type}} = 'Психологические' AND role_group = 'ФОТ Психологи' ) )
    GROUP BY mnum, role_group
),
payroll_pivot AS (
    SELECT
        mnum,
        sum(fot_pct)                                                    AS fot_total_pct,
        sum(fot_oklad)                                                  AS fot_total_oklad,
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
        sum(taxes)                                                      AS taxes_total,
        sumIf(taxes, role_group = 'ФОТ Психиатры')                      AS taxes_psy,
        sumIf(taxes, role_group = 'ФОТ Психологи')                      AS taxes_pso,
        sumIf(taxes, role_group = 'ФОТ Администраторы')                 AS taxes_adm,
        sumIf(taxes, role_group = 'ФОТ Управление')                     AS taxes_upr,
        sumIf(taxes, role_group = 'ФОТ Маркетинг')                      AS taxes_mkt,
        sumIf(taxes, role_group = 'ФОТ ШАА')                            AS taxes_shaa
    FROM payroll_f
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
        -- делитель: клиент или визит, по параметру {{unit}}
        if({{unit}} = 'Клиент', r.clients, r.visits) AS denom
    FROM monthly_rev r
    FULL OUTER JOIN payroll_pivot p ON r.mnum = p.mnum
)
SELECT "Метрика", "Янв","Фев","Мар","Апр","Май","Июн","Июл","Авг","Сен","Окт","Ноя","Дек","За год"
FROM (
SELECT 1 AS rn, 'Выручка' AS "Метрика",
    toFloat64(sumIf(revenue, mnum=1)) AS "Янв", toFloat64(sumIf(revenue, mnum=2)) AS "Фев", toFloat64(sumIf(revenue, mnum=3)) AS "Мар",
    toFloat64(sumIf(revenue, mnum=4)) AS "Апр", toFloat64(sumIf(revenue, mnum=5)) AS "Май", toFloat64(sumIf(revenue, mnum=6)) AS "Июн",
    toFloat64(sumIf(revenue, mnum=7)) AS "Июл", toFloat64(sumIf(revenue, mnum=8)) AS "Авг", toFloat64(sumIf(revenue, mnum=9)) AS "Сен",
    toFloat64(sumIf(revenue, mnum=10)) AS "Окт", toFloat64(sumIf(revenue, mnum=11)) AS "Ноя", toFloat64(sumIf(revenue, mnum=12)) AS "Дек",
    toFloat64(sum(revenue)) AS "За год"
FROM monthly
UNION ALL
SELECT 2, 'Выручка на ' || lower({{unit}}),
    toFloat64(sumIf(revenue,mnum=1))/nullIf(toFloat64(sumIf(denom,mnum=1)),0), toFloat64(sumIf(revenue,mnum=2))/nullIf(toFloat64(sumIf(denom,mnum=2)),0),
    toFloat64(sumIf(revenue,mnum=3))/nullIf(toFloat64(sumIf(denom,mnum=3)),0), toFloat64(sumIf(revenue,mnum=4))/nullIf(toFloat64(sumIf(denom,mnum=4)),0),
    toFloat64(sumIf(revenue,mnum=5))/nullIf(toFloat64(sumIf(denom,mnum=5)),0), toFloat64(sumIf(revenue,mnum=6))/nullIf(toFloat64(sumIf(denom,mnum=6)),0),
    toFloat64(sumIf(revenue,mnum=7))/nullIf(toFloat64(sumIf(denom,mnum=7)),0), toFloat64(sumIf(revenue,mnum=8))/nullIf(toFloat64(sumIf(denom,mnum=8)),0),
    toFloat64(sumIf(revenue,mnum=9))/nullIf(toFloat64(sumIf(denom,mnum=9)),0), toFloat64(sumIf(revenue,mnum=10))/nullIf(toFloat64(sumIf(denom,mnum=10)),0),
    toFloat64(sumIf(revenue,mnum=11))/nullIf(toFloat64(sumIf(denom,mnum=11)),0), toFloat64(sumIf(revenue,mnum=12))/nullIf(toFloat64(sumIf(denom,mnum=12)),0),
    toFloat64(sum(revenue))/nullIf(toFloat64(sum(denom)),0)
FROM monthly
UNION ALL
SELECT 3, 'Визиты',
    toFloat64(sumIf(visits,mnum=1)), toFloat64(sumIf(visits,mnum=2)), toFloat64(sumIf(visits,mnum=3)), toFloat64(sumIf(visits,mnum=4)),
    toFloat64(sumIf(visits,mnum=5)), toFloat64(sumIf(visits,mnum=6)), toFloat64(sumIf(visits,mnum=7)), toFloat64(sumIf(visits,mnum=8)),
    toFloat64(sumIf(visits,mnum=9)), toFloat64(sumIf(visits,mnum=10)), toFloat64(sumIf(visits,mnum=11)), toFloat64(sumIf(visits,mnum=12)),
    toFloat64(sum(visits))
FROM monthly
UNION ALL
SELECT 4, 'Клиенты',
    toFloat64(sumIf(clients,mnum=1)), toFloat64(sumIf(clients,mnum=2)), toFloat64(sumIf(clients,mnum=3)), toFloat64(sumIf(clients,mnum=4)),
    toFloat64(sumIf(clients,mnum=5)), toFloat64(sumIf(clients,mnum=6)), toFloat64(sumIf(clients,mnum=7)), toFloat64(sumIf(clients,mnum=8)),
    toFloat64(sumIf(clients,mnum=9)), toFloat64(sumIf(clients,mnum=10)), toFloat64(sumIf(clients,mnum=11)), toFloat64(sumIf(clients,mnum=12)),
    toFloat64(sum(clients))
FROM monthly
UNION ALL
SELECT 5, 'Новые клиенты',
    toFloat64(sumIf(new_clients,mnum=1)), toFloat64(sumIf(new_clients,mnum=2)), toFloat64(sumIf(new_clients,mnum=3)), toFloat64(sumIf(new_clients,mnum=4)),
    toFloat64(sumIf(new_clients,mnum=5)), toFloat64(sumIf(new_clients,mnum=6)), toFloat64(sumIf(new_clients,mnum=7)), toFloat64(sumIf(new_clients,mnum=8)),
    toFloat64(sumIf(new_clients,mnum=9)), toFloat64(sumIf(new_clients,mnum=10)), toFloat64(sumIf(new_clients,mnum=11)), toFloat64(sumIf(new_clients,mnum=12)),
    toFloat64(sum(new_clients))
FROM monthly
UNION ALL
SELECT 6, 'ФОТ всего — Проценты',
    toFloat64(sumIf(fot_total_pct,mnum=1)), toFloat64(sumIf(fot_total_pct,mnum=2)), toFloat64(sumIf(fot_total_pct,mnum=3)), toFloat64(sumIf(fot_total_pct,mnum=4)),
    toFloat64(sumIf(fot_total_pct,mnum=5)), toFloat64(sumIf(fot_total_pct,mnum=6)), toFloat64(sumIf(fot_total_pct,mnum=7)), toFloat64(sumIf(fot_total_pct,mnum=8)),
    toFloat64(sumIf(fot_total_pct,mnum=9)), toFloat64(sumIf(fot_total_pct,mnum=10)), toFloat64(sumIf(fot_total_pct,mnum=11)), toFloat64(sumIf(fot_total_pct,mnum=12)),
    toFloat64(sum(fot_total_pct))
FROM monthly
UNION ALL
SELECT 7, 'ФОТ всего — Оклад+Бонус',
    toFloat64(sumIf(fot_total_oklad,mnum=1)), toFloat64(sumIf(fot_total_oklad,mnum=2)), toFloat64(sumIf(fot_total_oklad,mnum=3)), toFloat64(sumIf(fot_total_oklad,mnum=4)),
    toFloat64(sumIf(fot_total_oklad,mnum=5)), toFloat64(sumIf(fot_total_oklad,mnum=6)), toFloat64(sumIf(fot_total_oklad,mnum=7)), toFloat64(sumIf(fot_total_oklad,mnum=8)),
    toFloat64(sumIf(fot_total_oklad,mnum=9)), toFloat64(sumIf(fot_total_oklad,mnum=10)), toFloat64(sumIf(fot_total_oklad,mnum=11)), toFloat64(sumIf(fot_total_oklad,mnum=12)),
    toFloat64(sum(fot_total_oklad))
FROM monthly
UNION ALL
SELECT 8, 'ФОТ Психиатры — Проценты',
    toFloat64(sumIf(psy_pct,mnum=1)), toFloat64(sumIf(psy_pct,mnum=2)), toFloat64(sumIf(psy_pct,mnum=3)), toFloat64(sumIf(psy_pct,mnum=4)),
    toFloat64(sumIf(psy_pct,mnum=5)), toFloat64(sumIf(psy_pct,mnum=6)), toFloat64(sumIf(psy_pct,mnum=7)), toFloat64(sumIf(psy_pct,mnum=8)),
    toFloat64(sumIf(psy_pct,mnum=9)), toFloat64(sumIf(psy_pct,mnum=10)), toFloat64(sumIf(psy_pct,mnum=11)), toFloat64(sumIf(psy_pct,mnum=12)),
    toFloat64(sum(psy_pct))
FROM monthly
UNION ALL
SELECT 9, 'ФОТ Психиатры — Оклад+Бонус',
    toFloat64(sumIf(psy_oklad,mnum=1)), toFloat64(sumIf(psy_oklad,mnum=2)), toFloat64(sumIf(psy_oklad,mnum=3)), toFloat64(sumIf(psy_oklad,mnum=4)),
    toFloat64(sumIf(psy_oklad,mnum=5)), toFloat64(sumIf(psy_oklad,mnum=6)), toFloat64(sumIf(psy_oklad,mnum=7)), toFloat64(sumIf(psy_oklad,mnum=8)),
    toFloat64(sumIf(psy_oklad,mnum=9)), toFloat64(sumIf(psy_oklad,mnum=10)), toFloat64(sumIf(psy_oklad,mnum=11)), toFloat64(sumIf(psy_oklad,mnum=12)),
    toFloat64(sum(psy_oklad))
FROM monthly
UNION ALL
SELECT 10, 'ФОТ Психологи — Проценты',
    toFloat64(sumIf(pso_pct,mnum=1)), toFloat64(sumIf(pso_pct,mnum=2)), toFloat64(sumIf(pso_pct,mnum=3)), toFloat64(sumIf(pso_pct,mnum=4)),
    toFloat64(sumIf(pso_pct,mnum=5)), toFloat64(sumIf(pso_pct,mnum=6)), toFloat64(sumIf(pso_pct,mnum=7)), toFloat64(sumIf(pso_pct,mnum=8)),
    toFloat64(sumIf(pso_pct,mnum=9)), toFloat64(sumIf(pso_pct,mnum=10)), toFloat64(sumIf(pso_pct,mnum=11)), toFloat64(sumIf(pso_pct,mnum=12)),
    toFloat64(sum(pso_pct))
FROM monthly
UNION ALL
SELECT 11, 'ФОТ Психологи — Оклад+Бонус',
    toFloat64(sumIf(pso_oklad,mnum=1)), toFloat64(sumIf(pso_oklad,mnum=2)), toFloat64(sumIf(pso_oklad,mnum=3)), toFloat64(sumIf(pso_oklad,mnum=4)),
    toFloat64(sumIf(pso_oklad,mnum=5)), toFloat64(sumIf(pso_oklad,mnum=6)), toFloat64(sumIf(pso_oklad,mnum=7)), toFloat64(sumIf(pso_oklad,mnum=8)),
    toFloat64(sumIf(pso_oklad,mnum=9)), toFloat64(sumIf(pso_oklad,mnum=10)), toFloat64(sumIf(pso_oklad,mnum=11)), toFloat64(sumIf(pso_oklad,mnum=12)),
    toFloat64(sum(pso_oklad))
FROM monthly
UNION ALL
SELECT 12, 'ФОТ Администраторы — Проценты',
    toFloat64(sumIf(adm_pct,mnum=1)), toFloat64(sumIf(adm_pct,mnum=2)), toFloat64(sumIf(adm_pct,mnum=3)), toFloat64(sumIf(adm_pct,mnum=4)),
    toFloat64(sumIf(adm_pct,mnum=5)), toFloat64(sumIf(adm_pct,mnum=6)), toFloat64(sumIf(adm_pct,mnum=7)), toFloat64(sumIf(adm_pct,mnum=8)),
    toFloat64(sumIf(adm_pct,mnum=9)), toFloat64(sumIf(adm_pct,mnum=10)), toFloat64(sumIf(adm_pct,mnum=11)), toFloat64(sumIf(adm_pct,mnum=12)),
    toFloat64(sum(adm_pct))
FROM monthly
UNION ALL
SELECT 13, 'ФОТ Администраторы — Оклад+Бонус',
    toFloat64(sumIf(adm_oklad,mnum=1)), toFloat64(sumIf(adm_oklad,mnum=2)), toFloat64(sumIf(adm_oklad,mnum=3)), toFloat64(sumIf(adm_oklad,mnum=4)),
    toFloat64(sumIf(adm_oklad,mnum=5)), toFloat64(sumIf(adm_oklad,mnum=6)), toFloat64(sumIf(adm_oklad,mnum=7)), toFloat64(sumIf(adm_oklad,mnum=8)),
    toFloat64(sumIf(adm_oklad,mnum=9)), toFloat64(sumIf(adm_oklad,mnum=10)), toFloat64(sumIf(adm_oklad,mnum=11)), toFloat64(sumIf(adm_oklad,mnum=12)),
    toFloat64(sum(adm_oklad))
FROM monthly
UNION ALL
SELECT 14, 'ФОТ Управление — Проценты',
    toFloat64(sumIf(upr_pct,mnum=1)), toFloat64(sumIf(upr_pct,mnum=2)), toFloat64(sumIf(upr_pct,mnum=3)), toFloat64(sumIf(upr_pct,mnum=4)),
    toFloat64(sumIf(upr_pct,mnum=5)), toFloat64(sumIf(upr_pct,mnum=6)), toFloat64(sumIf(upr_pct,mnum=7)), toFloat64(sumIf(upr_pct,mnum=8)),
    toFloat64(sumIf(upr_pct,mnum=9)), toFloat64(sumIf(upr_pct,mnum=10)), toFloat64(sumIf(upr_pct,mnum=11)), toFloat64(sumIf(upr_pct,mnum=12)),
    toFloat64(sum(upr_pct))
FROM monthly
UNION ALL
SELECT 15, 'ФОТ Управление — Оклад+Бонус',
    toFloat64(sumIf(upr_oklad,mnum=1)), toFloat64(sumIf(upr_oklad,mnum=2)), toFloat64(sumIf(upr_oklad,mnum=3)), toFloat64(sumIf(upr_oklad,mnum=4)),
    toFloat64(sumIf(upr_oklad,mnum=5)), toFloat64(sumIf(upr_oklad,mnum=6)), toFloat64(sumIf(upr_oklad,mnum=7)), toFloat64(sumIf(upr_oklad,mnum=8)),
    toFloat64(sumIf(upr_oklad,mnum=9)), toFloat64(sumIf(upr_oklad,mnum=10)), toFloat64(sumIf(upr_oklad,mnum=11)), toFloat64(sumIf(upr_oklad,mnum=12)),
    toFloat64(sum(upr_oklad))
FROM monthly
UNION ALL
SELECT 16, 'ФОТ Маркетинг — Проценты',
    toFloat64(sumIf(mkt_pct,mnum=1)), toFloat64(sumIf(mkt_pct,mnum=2)), toFloat64(sumIf(mkt_pct,mnum=3)), toFloat64(sumIf(mkt_pct,mnum=4)),
    toFloat64(sumIf(mkt_pct,mnum=5)), toFloat64(sumIf(mkt_pct,mnum=6)), toFloat64(sumIf(mkt_pct,mnum=7)), toFloat64(sumIf(mkt_pct,mnum=8)),
    toFloat64(sumIf(mkt_pct,mnum=9)), toFloat64(sumIf(mkt_pct,mnum=10)), toFloat64(sumIf(mkt_pct,mnum=11)), toFloat64(sumIf(mkt_pct,mnum=12)),
    toFloat64(sum(mkt_pct))
FROM monthly
UNION ALL
SELECT 17, 'ФОТ Маркетинг — Оклад+Бонус',
    toFloat64(sumIf(mkt_oklad,mnum=1)), toFloat64(sumIf(mkt_oklad,mnum=2)), toFloat64(sumIf(mkt_oklad,mnum=3)), toFloat64(sumIf(mkt_oklad,mnum=4)),
    toFloat64(sumIf(mkt_oklad,mnum=5)), toFloat64(sumIf(mkt_oklad,mnum=6)), toFloat64(sumIf(mkt_oklad,mnum=7)), toFloat64(sumIf(mkt_oklad,mnum=8)),
    toFloat64(sumIf(mkt_oklad,mnum=9)), toFloat64(sumIf(mkt_oklad,mnum=10)), toFloat64(sumIf(mkt_oklad,mnum=11)), toFloat64(sumIf(mkt_oklad,mnum=12)),
    toFloat64(sum(mkt_oklad))
FROM monthly
UNION ALL
SELECT 18, 'ФОТ ШАА — Проценты',
    toFloat64(sumIf(shaa_pct,mnum=1)), toFloat64(sumIf(shaa_pct,mnum=2)), toFloat64(sumIf(shaa_pct,mnum=3)), toFloat64(sumIf(shaa_pct,mnum=4)),
    toFloat64(sumIf(shaa_pct,mnum=5)), toFloat64(sumIf(shaa_pct,mnum=6)), toFloat64(sumIf(shaa_pct,mnum=7)), toFloat64(sumIf(shaa_pct,mnum=8)),
    toFloat64(sumIf(shaa_pct,mnum=9)), toFloat64(sumIf(shaa_pct,mnum=10)), toFloat64(sumIf(shaa_pct,mnum=11)), toFloat64(sumIf(shaa_pct,mnum=12)),
    toFloat64(sum(shaa_pct))
FROM monthly
UNION ALL
SELECT 19, 'ФОТ ШАА — Оклад+Бонус',
    toFloat64(sumIf(shaa_oklad,mnum=1)), toFloat64(sumIf(shaa_oklad,mnum=2)), toFloat64(sumIf(shaa_oklad,mnum=3)), toFloat64(sumIf(shaa_oklad,mnum=4)),
    toFloat64(sumIf(shaa_oklad,mnum=5)), toFloat64(sumIf(shaa_oklad,mnum=6)), toFloat64(sumIf(shaa_oklad,mnum=7)), toFloat64(sumIf(shaa_oklad,mnum=8)),
    toFloat64(sumIf(shaa_oklad,mnum=9)), toFloat64(sumIf(shaa_oklad,mnum=10)), toFloat64(sumIf(shaa_oklad,mnum=11)), toFloat64(sumIf(shaa_oklad,mnum=12)),
    toFloat64(sum(shaa_oklad))
FROM monthly
UNION ALL
SELECT 20, 'Налоги и взносы с ФОТ',
    toFloat64(sumIf(taxes_total,mnum=1)), toFloat64(sumIf(taxes_total,mnum=2)), toFloat64(sumIf(taxes_total,mnum=3)), toFloat64(sumIf(taxes_total,mnum=4)),
    toFloat64(sumIf(taxes_total,mnum=5)), toFloat64(sumIf(taxes_total,mnum=6)), toFloat64(sumIf(taxes_total,mnum=7)), toFloat64(sumIf(taxes_total,mnum=8)),
    toFloat64(sumIf(taxes_total,mnum=9)), toFloat64(sumIf(taxes_total,mnum=10)), toFloat64(sumIf(taxes_total,mnum=11)), toFloat64(sumIf(taxes_total,mnum=12)),
    toFloat64(sum(taxes_total))
FROM monthly
UNION ALL
SELECT 21, 'Доля ФОТ в выручке, %',
    toFloat64(sumIf(fot_total,mnum=1))/nullIf(toFloat64(sumIf(revenue,mnum=1)),0)*100, toFloat64(sumIf(fot_total,mnum=2))/nullIf(toFloat64(sumIf(revenue,mnum=2)),0)*100,
    toFloat64(sumIf(fot_total,mnum=3))/nullIf(toFloat64(sumIf(revenue,mnum=3)),0)*100, toFloat64(sumIf(fot_total,mnum=4))/nullIf(toFloat64(sumIf(revenue,mnum=4)),0)*100,
    toFloat64(sumIf(fot_total,mnum=5))/nullIf(toFloat64(sumIf(revenue,mnum=5)),0)*100, toFloat64(sumIf(fot_total,mnum=6))/nullIf(toFloat64(sumIf(revenue,mnum=6)),0)*100,
    toFloat64(sumIf(fot_total,mnum=7))/nullIf(toFloat64(sumIf(revenue,mnum=7)),0)*100, toFloat64(sumIf(fot_total,mnum=8))/nullIf(toFloat64(sumIf(revenue,mnum=8)),0)*100,
    toFloat64(sumIf(fot_total,mnum=9))/nullIf(toFloat64(sumIf(revenue,mnum=9)),0)*100, toFloat64(sumIf(fot_total,mnum=10))/nullIf(toFloat64(sumIf(revenue,mnum=10)),0)*100,
    toFloat64(sumIf(fot_total,mnum=11))/nullIf(toFloat64(sumIf(revenue,mnum=11)),0)*100, toFloat64(sumIf(fot_total,mnum=12))/nullIf(toFloat64(sumIf(revenue,mnum=12)),0)*100,
    toFloat64(sum(fot_total))/nullIf(toFloat64(sum(revenue)),0)*100
FROM monthly
UNION ALL
SELECT 22, 'Прибыль после ФОТ',
    toFloat64(sumIf(revenue,mnum=1))-coalesce(toFloat64(sumIf(fot_total,mnum=1)),0)+coalesce(toFloat64(sumIf(taxes_total,mnum=1)),0),
    toFloat64(sumIf(revenue,mnum=2))-coalesce(toFloat64(sumIf(fot_total,mnum=2)),0)+coalesce(toFloat64(sumIf(taxes_total,mnum=2)),0),
    toFloat64(sumIf(revenue,mnum=3))-coalesce(toFloat64(sumIf(fot_total,mnum=3)),0)+coalesce(toFloat64(sumIf(taxes_total,mnum=3)),0),
    toFloat64(sumIf(revenue,mnum=4))-coalesce(toFloat64(sumIf(fot_total,mnum=4)),0)+coalesce(toFloat64(sumIf(taxes_total,mnum=4)),0),
    toFloat64(sumIf(revenue,mnum=5))-coalesce(toFloat64(sumIf(fot_total,mnum=5)),0)+coalesce(toFloat64(sumIf(taxes_total,mnum=5)),0),
    toFloat64(sumIf(revenue,mnum=6))-coalesce(toFloat64(sumIf(fot_total,mnum=6)),0)+coalesce(toFloat64(sumIf(taxes_total,mnum=6)),0),
    toFloat64(sumIf(revenue,mnum=7))-coalesce(toFloat64(sumIf(fot_total,mnum=7)),0)+coalesce(toFloat64(sumIf(taxes_total,mnum=7)),0),
    toFloat64(sumIf(revenue,mnum=8))-coalesce(toFloat64(sumIf(fot_total,mnum=8)),0)+coalesce(toFloat64(sumIf(taxes_total,mnum=8)),0),
    toFloat64(sumIf(revenue,mnum=9))-coalesce(toFloat64(sumIf(fot_total,mnum=9)),0)+coalesce(toFloat64(sumIf(taxes_total,mnum=9)),0),
    toFloat64(sumIf(revenue,mnum=10))-coalesce(toFloat64(sumIf(fot_total,mnum=10)),0)+coalesce(toFloat64(sumIf(taxes_total,mnum=10)),0),
    toFloat64(sumIf(revenue,mnum=11))-coalesce(toFloat64(sumIf(fot_total,mnum=11)),0)+coalesce(toFloat64(sumIf(taxes_total,mnum=11)),0),
    toFloat64(sumIf(revenue,mnum=12))-coalesce(toFloat64(sumIf(fot_total,mnum=12)),0)+coalesce(toFloat64(sumIf(taxes_total,mnum=12)),0),
    toFloat64(sum(revenue))-coalesce(toFloat64(sum(fot_total)),0)+coalesce(toFloat64(sum(taxes_total)),0)
FROM monthly
UNION ALL
SELECT 23, 'Прибыль после ФОТ на ' || lower({{unit}}),
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
) ORDER BY rn
