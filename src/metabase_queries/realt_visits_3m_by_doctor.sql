-- Metabase: native SQL карточка «Таблица - Реальт - Визиты за 3 мес по
-- врачам» дашборда «Реальт - Визиты за 3 мес по врачам».
-- 2026-09-24, по просьбе владельца: та же идея, что строка «Визиты на
-- нового клиента (3 мес, скользящее)» на дашборде «Ежемесячные метрики»
-- (карточка 186, realt_monthly_metrics.sql), но разрезанная ПО ВРАЧАМ:
-- строки — ФИО врачей, сгруппированные по типу (Психиатры/Психологи),
-- столбцы — месяцы выбранного года (параметр year).

-- ОПРЕДЕЛЕНИЕ МЕТРИКИ (согласовано с владельцем 2026-09-24, отличается
-- от общеклинической строки на дашборде 8 в двух местах — см. ниже):
--   * Когорта месяца M — клиенты, чей ПЕРВЫЙ визит в клинику за всю
--     историю пришёлся на месяц M. Каждый такой клиент закрепляется за
--     ВРАЧОМ ЭТОГО ПЕРВОГО ВИЗИТА — значит любой клиент попадает ровно к
--     одному врачу, и сумма знаменателей по врачам равна общему числу
--     новых клиентов месяца.
--   * Числитель — только визиты клиента К ЭТОМУ ЖЕ ВРАЧУ, попавшие в
--     скользящее окно [M .. M+2 мес.] включительно (месяц привлечения +
--     два следующих; НЕ календарный квартал). Уходы к другим врачам
--     клиники НЕ считаются — метрика отвечает на «сколько визитов врач
--     удерживает лично», а не «сколько стоит приведённый им клиент».
--   * Значение = числитель / знаменатель, минимум 1.00 (сам первый визит
--     всегда внутри окна). Значение < 1.00 в этой таблице невозможно —
--     если такое появилось, запрос сломан (см. ГОЧТЯ 4 ниже, ровно этот
--     симптом уже поймали при разработке).
--   * ШАА (Шмилович, Онегина) НЕ исключается и тумблера include_shaa
--     здесь нет — эти врачи идут обычными строками и по роли из ФОТ
--     попадают в группу «Психиатры» (у Шмиловича role = 'ФОТ Шмилович',
--     у Онегиной — 'ФОТ Психиатры' при department = 'ШАА').
-- ИЗ-ЗА ЭТИХ ДВУХ ОТЛИЧИЙ (только свой врач в числителе + ШАА внутри)
-- строка «ВСЯ КЛИНИКА / ИТОГО» здесь НЕ совпадает и не должна совпадать
-- со строкой дашборда 8 — там числитель это ВСЕ визиты когорты, а ШАА
-- выкинут из последовательности первых визитов.

-- Тип врача берётся из realt_payroll.role по ПОСЛЕДНЕМУ периоду
-- (argMax(role, period)), а НЕ из realt_visits_categorized.role_group.
-- Причина: role_group считается по наличию строки ФОТ В МЕСЯЦЕ ВИЗИТА, и
-- до 2025-01 (нет загруженного ФОТ) он равен 'Без ФОТ-кода' у всех — по
-- нему один и тот же врач попал бы в разные группы в разные годы.
-- Врачи, которых вообще нет в ФОТ (уволились до 2025), и немедицинские
-- роли (администраторы, принимавшие визиты) идут в группу «Прочие».

-- ВАЖНО, незавершённое окно: у последних 1-2 загруженных месяцев окно
-- [M..M+2] уходит в ещё не загруженные визиты, поэтому значение там
-- занижено технически, а не по факту (тот же дисклеймер, что у
-- new_client_visits_3m в schema_realt_metrics_views.sql). Отдельная
-- карточка «Новые клиенты по врачам» на этом же дашборде показывает
-- знаменатель по месяцам — по нему видно, на сколько клиентов опирается
-- каждая ячейка (у врача с 1-2 новыми клиентами в месяце значение
-- статистически пустое). Пустая ячейка = в этом месяце у врача не было
-- НИ ОДНОГО нового клиента (делить не на что), а не ноль визитов.

-- Группировка строк сделана через GROUP BY GROUPING SETS: одна и та же
-- пачка sumIf-ов даёт и строки врачей, и «ИТОГО» по типу, и «ВСЯ
-- КЛИНИКА / ИТОГО». Итоговые строки — это НЕ среднее средних: числитель
-- и знаменатель суммируются по группе и делятся уже потом (та же ловушка
-- и то же решение, что у «За год» в realt_monthly_metrics.sql).

-- ГОЧТЯ (1-2 унаследованы от остальных карточек Реальта, 3-4 найдены на
-- этой карточке 2026-09-24):
-- 1) голая строка-комментарий "--" без пробела/текста после ломает разбор
--    параметров в ClickHouse JDBC-драйвере Metabase — в этом файле таких
--    строк нет намеренно (абзацы в шапке разделены пустой строкой, а не
--    строкой из двух дефисов);
-- 2) двойные фигурные скобки вокруг имени параметра в тексте комментария
--    движок тоже пытается разобрать — имя year выше упомянуто в скобках
--    только там, где оно реально есть в запросе;
-- 3) НЕ давать алиас колонке именем другой колонки того же скоупа
--    (`SELECT acquisition_month AS month, countIf(month >= acquisition_month ...)`)
--    — внутри агрегата `month` разрешается в АЛИАС, а не в исходную
--    колонку, условие вырождается в тождество и окно молча перестаёт
--    работать. Именно этот баг сидел в rolling_m в
--    schema_realt_metrics_views.sql (найден при сверке с этой карточкой).
--    Поэтому здесь все алиасы (acq_*/pc_*/doc_*) намеренно НЕ повторяют
--    имена колонок realt_visits_categorized;
-- 4) НЕ опираться на realt_visits_categorized.visit_seq для определения
--    «врача первого визита» и НЕ ссылаться на такую когорту из двух CTE.
--    visit_seq = row_number() OVER (ORDER BY visit_start) без tie-break,
--    а у 98 клиентов (из 8072) первый визит — это НЕСКОЛЬКО визитов с
--    одинаковым visit_start к РАЗНЫМ врачам: кому из них достанется
--    visit_seq = 1, решается произвольно и МЕНЯЕТСЯ ОТ ЗАПУСКА К ЗАПУСКУ.
--    А так как CTE в ClickHouse подставляются текстом (не
--    материализуются), числитель и знаменатель, посчитанные в двух разных
--    CTE над одной и той же «когортой», расходились между собой — в
--    таблице появлялись значения 0.91 и даже 0.00, невозможные по
--    определению метрики. Здесь вместо этого: детерминированный
--    argMin(..., (visit_start, doctor_name)) — tie-break по алфавиту ФИО
--    — и ОДИН проход per_client, дающий числитель и знаменатель разом.

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
    -- делает выбор врача детерминированным (см. ГОЧТЯ 4).
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
-- дефолтом типа) — поэтому и подписи итоговых строк, и ORDER BY идут
-- через coalesce(); без него `doc_fio = ''` даёт NULL, подпись «ИТОГО»
-- не подставляется, а итоговая строка уезжает в конец группы.
SELECT
    if(coalesce(doc_group, '') = '', 'ВСЯ КЛИНИКА', doc_group) AS "Тип",
    if(coalesce(doc_fio, '')   = '', 'ИТОГО',       doc_fio)   AS "Врач",
    sumIf(visits_3m, mnum = 1)  / nullIf(sumIf(new_clients, mnum = 1),  0) AS "Янв",
    sumIf(visits_3m, mnum = 2)  / nullIf(sumIf(new_clients, mnum = 2),  0) AS "Фев",
    sumIf(visits_3m, mnum = 3)  / nullIf(sumIf(new_clients, mnum = 3),  0) AS "Мар",
    sumIf(visits_3m, mnum = 4)  / nullIf(sumIf(new_clients, mnum = 4),  0) AS "Апр",
    sumIf(visits_3m, mnum = 5)  / nullIf(sumIf(new_clients, mnum = 5),  0) AS "Май",
    sumIf(visits_3m, mnum = 6)  / nullIf(sumIf(new_clients, mnum = 6),  0) AS "Июн",
    sumIf(visits_3m, mnum = 7)  / nullIf(sumIf(new_clients, mnum = 7),  0) AS "Июл",
    sumIf(visits_3m, mnum = 8)  / nullIf(sumIf(new_clients, mnum = 8),  0) AS "Авг",
    sumIf(visits_3m, mnum = 9)  / nullIf(sumIf(new_clients, mnum = 9),  0) AS "Сен",
    sumIf(visits_3m, mnum = 10) / nullIf(sumIf(new_clients, mnum = 10), 0) AS "Окт",
    sumIf(visits_3m, mnum = 11) / nullIf(sumIf(new_clients, mnum = 11), 0) AS "Ноя",
    sumIf(visits_3m, mnum = 12) / nullIf(sumIf(new_clients, mnum = 12), 0) AS "Дек",
    sum(visits_3m) / nullIf(sum(new_clients), 0)                           AS "За год",
    toFloat64(sum(new_clients))                                            AS "Новых клиентов за год"
FROM metric
GROUP BY GROUPING SETS ((doc_ord, doc_group, doc_fio), (doc_ord, doc_group), ())
ORDER BY
    coalesce(doc_ord, 0) ASC,
    (coalesce(doc_fio, '') != '') ASC,
    "Новых клиентов за год" DESC,
    "Врач" ASC
SETTINGS query_plan_max_optimizations_to_apply = 100000
