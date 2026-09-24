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

-- РАСКЛАДКА (переделана 2026-09-24 по просьбе владельца: «сделать как
-- сводную, не так страшно»). Отдельной колонки «Тип» больше НЕТ — вместо
-- неё перед каждой группой идёт строка-заголовок с названием группы
-- капсом («ПСИХИАТРЫ»/«ПСИХОЛОГИ»/«ПРОЧИЕ»), а врачи под ней — просто
-- по фамилии. В Metabase заголовки подсвечены фоном через
-- table.column_formatting (три правила highlight_row по точному
-- совпадению текста в колонке «Врач»), поэтому набор этих трёх строк
-- нельзя менять, не поправив visualization_settings карточки.
-- В строке-заголовке заполнена ТОЛЬКО «Новых клиентов за год» (обычная
-- сумма, складывается корректно). Месячные значения и «За год» там
-- ПУСТЫЕ СОЗНАТЕЛЬНО: усреднять метрику по группе врачей нельзя по той
-- же причине, по которой убрана строка «ВСЯ КЛИНИКА» — в числителе
-- только визиты к СВОЕМУ врачу, поэтому клиент, перешедший от одного
-- психиатра к другому, в групповом среднем всё равно не учитывается, и
-- такое «среднее по группе» вводило бы в заблуждение.
-- Строка «ВСЯ КЛИНИКА / ИТОГО» и строки «ИТОГО» по типам УБРАНЫ
-- (2026-09-24, та же просьба) — раньше они считались через
-- GROUP BY GROUPING SETS, теперь его здесь нет.

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
--    schema_realt_metrics_views.sql — найден при сверке с этой карточкой и
--    починен 2026-09-24 (алиас переименован в cohort_month, строка карточки
--    186 «Визиты на нового клиента (3 мес, скользящее)» за январь 2026
--    стала 2.16 вместо 2.81).
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
-- 5) Metabase 0.63.10 НЕ УМЕЕТ визуал «Сводная таблица» (display:
--    "pivot") на native SQL-карточке — проверено эмпирически 2026-09-24
--    на пробной карточке: с display "pivot" тот же запрос возвращает
--    искалеченный результат (служебная колонка pivot-grouping и строки
--    вида [0]), с display "table" — нормальные строки. Бэкендный
--    /api/card/:id/query/pivot на такой карточке отдаёт 404. Поэтому
--    «сводный» вид (месяцы в столбцах, группы в строках) собирается
--    вручную в самом SQL, как здесь и в остальных карточках Реальта.

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
),
doctors AS (
    -- Одна строка = один врач: 12 месячных значений + год.
    SELECT
        doc_group AS d_group,
        doc_ord   AS d_ord,
        doc_fio   AS d_fio,
        sumIf(visits_3m, mnum = 1 ) / nullIf(sumIf(new_clients, mnum = 1 ), 0) AS m01,
        sumIf(visits_3m, mnum = 2 ) / nullIf(sumIf(new_clients, mnum = 2 ), 0) AS m02,
        sumIf(visits_3m, mnum = 3 ) / nullIf(sumIf(new_clients, mnum = 3 ), 0) AS m03,
        sumIf(visits_3m, mnum = 4 ) / nullIf(sumIf(new_clients, mnum = 4 ), 0) AS m04,
        sumIf(visits_3m, mnum = 5 ) / nullIf(sumIf(new_clients, mnum = 5 ), 0) AS m05,
        sumIf(visits_3m, mnum = 6 ) / nullIf(sumIf(new_clients, mnum = 6 ), 0) AS m06,
        sumIf(visits_3m, mnum = 7 ) / nullIf(sumIf(new_clients, mnum = 7 ), 0) AS m07,
        sumIf(visits_3m, mnum = 8 ) / nullIf(sumIf(new_clients, mnum = 8 ), 0) AS m08,
        sumIf(visits_3m, mnum = 9 ) / nullIf(sumIf(new_clients, mnum = 9 ), 0) AS m09,
        sumIf(visits_3m, mnum = 10) / nullIf(sumIf(new_clients, mnum = 10), 0) AS m10,
        sumIf(visits_3m, mnum = 11) / nullIf(sumIf(new_clients, mnum = 11), 0) AS m11,
        sumIf(visits_3m, mnum = 12) / nullIf(sumIf(new_clients, mnum = 12), 0) AS m12,
        sum(visits_3m) / nullIf(sum(new_clients), 0) AS m_year,
        toFloat64(sum(new_clients)) AS nc_year
    FROM metric
    GROUP BY d_group, d_ord, d_fio
)
SELECT "Врач", "Янв", "Фев", "Мар", "Апр", "Май", "Июн", "Июл", "Авг", "Сен", "Окт", "Ноя", "Дек", "За год", "Новых клиентов за год"
FROM (
    -- Строка-заголовок группы (см. РАСКЛАДКА в шапке).
    SELECT
        d_ord                 AS ord,
        0                     AS is_doc,
        upperUTF8(d_group)    AS "Врач",
        CAST(NULL AS Nullable(Float64)) AS "Янв",
        CAST(NULL AS Nullable(Float64)) AS "Фев",
        CAST(NULL AS Nullable(Float64)) AS "Мар",
        CAST(NULL AS Nullable(Float64)) AS "Апр",
        CAST(NULL AS Nullable(Float64)) AS "Май",
        CAST(NULL AS Nullable(Float64)) AS "Июн",
        CAST(NULL AS Nullable(Float64)) AS "Июл",
        CAST(NULL AS Nullable(Float64)) AS "Авг",
        CAST(NULL AS Nullable(Float64)) AS "Сен",
        CAST(NULL AS Nullable(Float64)) AS "Окт",
        CAST(NULL AS Nullable(Float64)) AS "Ноя",
        CAST(NULL AS Nullable(Float64)) AS "Дек",
        CAST(NULL AS Nullable(Float64)) AS "За год",
        sum(nc_year) AS "Новых клиентов за год"
    FROM doctors
    GROUP BY ord, d_group
    UNION ALL
    SELECT
        d_ord, 1, d_fio,
        m01, m02, m03, m04, m05, m06, m07, m08, m09, m10, m11, m12,
        m_year,
        nc_year
    FROM doctors
)
ORDER BY
    ord ASC,
    is_doc ASC,
    "Новых клиентов за год" DESC,
    "Врач" ASC
SETTINGS query_plan_max_optimizations_to_apply = 100000
