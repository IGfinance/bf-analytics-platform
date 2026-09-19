-- Семантический слой метрик Реальта (Клиника) — формулы считаются здесь один
-- раз, Metabase Model становится тонкой обёрткой (см. architecture-standarts.md,
-- «Семантический слой для AI-бота», golden example wb_metrics_by_cabinet_month).
--
-- VIEW:
--   realt_visits_categorized/realt_payroll_categorized/realt_doctor_month/
--                            realt_role_month — юнит-экономика по врачу/роли
--                            (см. блок ниже), ОПРЕДЕЛЕНЫ ПЕРВЫМИ — от них
--                            зависит realt_metrics_by_month (исключение ШАА);
--   realt_metrics_by_month   — одна строка = месяц (выручка/визиты/клиенты/ФОТ);
--   realt_revenue_by_service — одна строка = (месяц, услуга): выручка по услугам;
--   realt_expenses_by_month  — «Остальные расходы» (Google-Таблица) по типу статьи помесячно;
--   realt_pl_by_group_month  — P&L по группам статей из «Расчетного счета»/
--                              «Наличных»/«Начислений» + ФОТ Маркетинга/Управления.
--
-- 2026-09-17: исправлен баг в realt_metrics_by_month — JOIN klientiks_m/payroll_m
-- был LEFT (от Клиентикс), из-за чего месяцы, где ФОТ уже загружен, а визитов
-- в Клиентикс ещё нет (напр. текущий месяц), молча пропадали из VIEW целиком —
-- не нулевые значения, а отсутствующая строка. Карточки 117/177 это уже
-- обходили через FULL OUTER JOIN у себя, в VIEW фикс не был перенесён.
-- Исправлено на FULL OUTER JOIN + coalesce(k.month, p.month).
--
-- Формулы согласованы с логикой дашборда realt-bi (realt.garaev.tech/clinic):
-- revenue=SUM(amount), визиты=COUNT(*), клиент=Номер карты, средний чек=
-- выручка/визиты; исключаются нулевые суммы, визиты подразделения ШАА и
-- исполнитель «тест».
--
-- ОТЛИЧИЕ ОТ realt-bi (осознанное, точнее): «новый клиент»/когорта считается
-- по вычисленному номеру визита (row_number по card_number, сорт. по дате),
-- а НЕ по колонке «Количество завершённых клиентов» — та в выгрузке ненадёжна
-- (пропуски/мусорные значения, у части клиентов нет строки со счётчиком=1),
-- из-за чего когорты realt-bi занижены. Сырое значение колонки лежит в
-- klientiks_operations.completed_count как есть.
--
-- Согласовано с клиентом (2026-09-14):
--   1) ФОТ = «Начислено ИТОГО» (accrued_total), не «К оплате»;
--   2) fot_revenue_share = (fot_total - fot_shmilovich) / revenue — ФОТ
--      Шмиловича исключён из доли, т.к. выручка тоже без Шмиловича.
-- ОСТАЁТСЯ ПОД ВОПРОСОМ: точность исходных данных Клиентикс (отметил клиент) —
-- финально сверить помесячные цифры с дашбордом realt.garaev.tech/clinic.
--
-- COMMENT COLUMN на VIEW может не поддерживаться старой версией ClickHouse —
-- накатывать ALTER по одному, проверяя system.columns (см. golden example).

-- 2026-09-17: добавлена разбивка ФОТ по pay_type (Оклад+Бонус/Проценты) —
-- раньше считалась отдельно и дублировалась в трёх Metabase Model
-- (98/119/120) и в карточках 117/177 напрямую в native SQL, без единой
-- версионируемой формулы. Заодно ключ исключения fot_shmilovich переведён
-- с role='ФОТ Шмилович' на department='ШАА' (согласовано с владельцем
-- 2026-09-17) — ВНИМАНИЕ: это ШИРЕ, чем раньше (department='ШАА' — 49 строк,
-- ~24.27М ₽, включает ещё администратора(ов)/психиатра ШАА-подразделения
-- сверх самого Шмиловича; role='ФОТ Шмилович' — 33 строки, ~22.97М ₽, строго
-- сам Шмилович). Это меняет уже показанные клиенту цифры «Доля ФОТ в
-- выручке»/«Прибыль после ФОТ» (согласовано 2026-09-14 было по старому
-- ключу) — при следующей сверке с клиентом упомянуть явно.
--
-- 2026-09-19: revenue/visits/clients/new_clients в realt_metrics_by_month
-- переведены с текстового исключения Шмиловича/Онегиной (position(service,
-- 'шмил'/'онег')) на тот же ключ, что уже использовался для fot_shmilovich —
-- department='ШАА' через realt_employees/realt_payroll (role_group='ФОТ ШАА'
-- в realt_visits_categorized, см. блок «Юнит-экономика по врачу» ниже).
-- Причина: текстовый фильтр давал ложные срабатывания/пропуски (см. историю
-- в том же блоке) И, что более важно для клиента, выручка и ФОТ считались
-- по РАЗНЫМ критериям исключения одного и того же понятия «ШАА» — теперь
-- единый ключ. Из-за этого VIEW пришлось переставить: realt_metrics_by_month
-- теперь зависит от realt_visits_categorized, поэтому та определена выше по
-- файлу. Это МЕНЯЕТ уже показанные клиенту цифры (revenue/avg_check/
-- new_clients/new_client_revenue) — при следующей сверке упомянуть явно.
-- «Новый клиент»/visit_seq пересчитывается ПОСЛЕ исключения ШАА (row_number
-- по отфильтрованному набору), а не переиспользует общий visit_seq из
-- realt_visits_categorized — сохраняет прежний смысл метрики («первый визит
-- к клинике без учёта ШАА»), меняется только критерий исключения.
--
-- realt_revenue_by_service НИЖЕ ПОКА НЕ ПЕРЕВЕДЕНА — там всё ещё текстовое
-- исключение 'шмил'/'онег'. Если нужно — тот же фикс отдельным шагом.
--
-- 2026-09-19 (тем же днём, вторая правка): при сверке с клиентской
-- отчётностью обнаружилось, что department='ШАА' в исходном виде тоже давал
-- неверные цифры за январь-март 2026 — потому что department у сотрудника
-- МЕНЯЕТСЯ СО ВРЕМЕНЕМ (Онегина Е.Ю.: «3 этаж»/Психиатры по март 2026
-- включительно, ШАА — с апреля 2026), а старый join брал «сотрудник
-- когда-либо был в ШАА» (DISTINCT employee_id без учёта периода) и относил
-- к ШАА весь стаж сотрудника задним числом. realt_visits_categorized и
-- realt_payroll_categorized переписаны на привязку department к КОНКРЕТНОМУ
-- МЕСЯЦУ (join/группировка по employee_id + месяц периода ФОТ) — см. их
-- собственные комментарии. Сверено с клиентской таблицей до рубля за
-- январь-март 2026 (561 000 / 510 500 / 347 000 ₽ — ровно выручка Онегиной
-- за эти месяцы, которая раньше вычиталась ошибочно).
--
-- 2026-09-19 (третья правка): по просьбе клиента добавлены full_revenue
-- («Полная выручка», ВСЕ визиты, с ШАА) и new_client_revenue_shaa («Выручка
-- с 1 визита ШАА» — тот же принцип, что new_client_revenue, но отдельная
-- последовательность visit_seq только по визитам ШАА, см. shaa_visits_seq).
-- new_client_revenue переименована в «Выручка с 1 визита» (формула не
-- менялась, только подпись в Metabase Model/карточке).
--
-- 2026-09-19 (четвёртая правка): добавлены new_clients_shaa («Кол-во 1
-- визитов ШАА») и new_client_visits_3m/new_client_visits_3m_avg («визиты
-- новых клиентов за скользящий квартал», см. rolling_m ниже) — по просьбе
-- клиента. «Кол-во 1 визитов» (без ШАА) — это существующая new_clients под
-- второй подписью в Model, отдельной колонки в VIEW под неё не заводили
-- (та же величина).

-- ═══════════════════════════════════════════════════════════════════════
-- Юнит-экономика по врачу (2026-09-17)
-- ═══════════════════════════════════════════════════════════════════════
--
-- Раньше ФОТ «на визит»/«на клиента» считался как (ФОТ всей роли за месяц) /
-- (визиты/клиенты ВСЕЙ клиники за месяц) — усреднение по больнице, а не по
-- конкретному врачу; выбрать одного врача и получить корректную цифру было
-- нельзя. Плюс исключение Шмиловича/Онегиной шло по названию услуги
-- (position(service, 'шмил'/'онег')) — не по личности врача, отсюда и ложные
-- срабатывания (услуга с чужим именем в составном названии), и пропуски
-- (визит Шмиловича с обычным названием услуги).
--
-- Ключ, который это чинит — realt_employees (employee_id ↔ ФИО, ФИО
-- совпадает с klientiks_operations.doctor с точностью до регистра, отсюда
-- upperUTF8(trim(...)) при сравнении). Через него зарплата (realt_payroll,
-- по employee_id) соединяется с приёмами (klientiks_operations, по doctor).
--
-- Три VIEW, от детального к агрегированному:
--   realt_visits_categorized  — один визит = одна строка, с employee_id и
--                               role_group (включая ФОТ ШАА — теперь по
--                               личности врача, не по названию услуги);
--   realt_payroll_categorized — одна строка realt_payroll, с той же
--                               категоризацией role_group;
--   realt_doctor_month        — месяц × врач: revenue/visits/clients из
--                               визитов ЭТОГО врача, fot из ЕГО зарплаты,
--                               fot_per_visit/fot_per_client — на этом уже
--                               корректны для одного конкретного врача;
--   realt_role_month          — месяц × роль (агрегат realt_doctor_month):
--                               «ФОТ Психиатры на визит» и т.п. теперь =
--                               ФОТ психиатров / ВИЗИТЫ, ПРИНЯТЫЕ психиатрами
--                               (а не визиты всей клиники, как раньше).
--
-- ШАА — не исключение/вычитание, а такая же полноценная категория role_group,
-- как «ФОТ Психиатры»/«ФОТ Психологи»: определяется по department='ШАА' в
-- realt_payroll (см. голову realt_metrics_by_month) — сейчас это Шмилович
-- Андрей Аркадьевич, Онегина Елена Юрьевна и их администратор Ерзаулова
-- Анастасия. Их приёмы (по ФИО, не по названию услуги) идут в ФОТ ШАА, а не
-- пропадают/не путаются с чужими визитами.
--
-- «Без ФОТ-кода» / «Не в справочнике сотрудников» — два разных случая
-- неполноты: первый — врач есть в realt_employees, но его employee_id не
-- находит пару в realt_payroll (старые/бывшие врачи вне системы ФОТ,
-- согласовано с владельцем 2026-09-17 — это ожидаемо, не баг); второй —
-- врач из Клиентикс вообще не найден в realt_employees. Оба видны отдельными
-- строками role_group, а не растворяются в других категориях — так пропуск
-- сразу заметен на дашборде, а не подделывает чужие цифры.

-- 2026-09-19: department привязан к КОНКРЕТНОМУ МЕСЯЦУ (join по
-- employee_id + месяц периода ФОТ), а не «сотрудник когда-либо был в ШАА»
-- (было DISTINCT employee_id без учёта периода). Найдено по факту сверки с
-- клиентской отчётностью: Онегина Е.Ю. была в отделе «3 этаж» (роль «ФОТ
-- Психиатры») по март 2026 включительно и переведена в ШАА только с апреля
-- 2026 — старый запрос ошибочно относил к ШАА и её визиты за январь-март
-- (задним числом), занижая revenue за эти месяцы ровно на её выручку
-- (561 000 / 510 500 / 347 000 ₽ — сверено с клиентом до рубля). Один
-- сотрудник может иметь НЕСКОЛЬКО строк ФОТ за один месяц с РАЗНЫМ
-- department (напр. администратор Ерзаулова — частичная занятость и на
-- этаже, и в ШАА) — считаем месяц «ШАА», если ШАА встретилась хотя бы в
-- одной строке ФОТ этого сотрудника за месяц (max(department='ШАА')).
CREATE OR REPLACE VIEW realt_visits_categorized AS
WITH doctor_key AS (
    SELECT employee_id, full_name, upperUTF8(trim(full_name)) AS name_key
    FROM realt_employees FINAL
    WHERE full_name IS NOT NULL AND full_name != ''
),
payroll_period AS (
    SELECT
        employee_id,
        toStartOfMonth(period)         AS period_month,
        max(department = 'ШАА')        AS is_shaa,
        argMax(role, period)           AS role,
        argMax(department, period)     AS pp_department
    FROM realt_payroll
    WHERE period IS NOT NULL
    GROUP BY employee_id, period_month
)
SELECT
    k.visit_start                                             AS visit_start,
    toDateTime(toStartOfMonth(k.visit_start)) + INTERVAL 12 HOUR AS month,
    k.card_number                                             AS card_number,
    k.amount                                                  AS amount,
    k.service                                                 AS service,
    nullIf(d.employee_id, '')                                 AS employee_id,
    coalesce(nullIf(d.full_name, ''), k.doctor)                AS doctor_name,
    multiIf(
        d.employee_id != '' AND pp.is_shaa = 1, 'ФОТ ШАА',
        d.employee_id != '' AND pp.role IS NOT NULL, pp.role,
        d.employee_id != '', 'Без ФОТ-кода',
        'Не в справочнике сотрудников'
    )                                                          AS role_group,
    -- 2026-09-19: visit_floor — независимая от role_group ось (найдено при
    -- сверке P&L с владельцем): department сотрудника В МЕСЯЦЕ ВИЗИТА,
    -- те же значения, что и в разделе «ФОТ по department» (2 этаж/3
    -- этаж/ШАА/УК) — на 2 и 3 этаже работают И психиатры, И психологи
    -- вперемешку, это НЕ то же самое, что «Тип врача». ШАА — и role_group,
    -- и visit_floor одновременно (пересечение множеств), у остальных
    -- visit_floor и role_group независимы. Названо НЕ "floor" — это
    -- зарезервированное имя функции в ClickHouse (математический floor()),
    -- голая колонка с таким именем ломает запросы к ней.
    multiIf(
        d.employee_id != '' AND pp.is_shaa = 1, 'ШАА',
        d.employee_id != '' AND pp.pp_department IS NOT NULL, pp.pp_department,
        NULL
    )                                                          AS visit_floor,
    row_number() OVER (PARTITION BY k.card_number ORDER BY k.visit_start) AS visit_seq
FROM klientiks_operations k
LEFT JOIN doctor_key d ON upperUTF8(trim(k.doctor)) = d.name_key
LEFT JOIN payroll_period pp
    ON d.employee_id = pp.employee_id
   AND toStartOfMonth(k.visit_start) = pp.period_month
WHERE k.amount > 0
  AND k.visit_start IS NOT NULL
  AND k.card_number != ''
  AND positionCaseInsensitiveUTF8(k.doctor, 'тест') = 0;

ALTER TABLE realt_visits_categorized COMMENT COLUMN month 'Начало месяца визита, время 12:00 (см. realt_metrics_by_month.month).';
ALTER TABLE realt_visits_categorized COMMENT COLUMN employee_id 'Код сотрудника (realt_employees/realt_payroll). NULL — врач не найден в справочнике сотрудников (см. role_group).';
ALTER TABLE realt_visits_categorized COMMENT COLUMN doctor_name 'ФИО врача — из справочника сотрудников, если найден, иначе как в Клиентикс (doctor).';
ALTER TABLE realt_visits_categorized COMMENT COLUMN role_group 'Категория: ФОТ Психиатры/Психологи/Администраторы/Управление/Маркетинг/ШАА — по department/role сотрудника В МЕСЯЦЕ ВИЗИТА (не «когда-либо», department может меняться со временем, см. историю 2026-09-19) — либо «Без ФОТ-кода»/«Не в справочнике сотрудников» при неполноте данных (в т.ч. если нет строки ФОТ именно за этот месяц).';
ALTER TABLE realt_visits_categorized COMMENT COLUMN visit_floor 'Этаж/блок (2 этаж/3 этаж/ШАА) по department сотрудника В МЕСЯЦЕ ВИЗИТА — независимая от role_group ось (добавлено 2026-09-19 для распределения накладных по этажам, см. docs/formulas/realt.tex). NULL — этаж не определён (нет department за этот месяц/сотрудник не найден).';
ALTER TABLE realt_visits_categorized COMMENT COLUMN visit_seq 'Порядковый номер визита клиента (по card_number, сортировка по дате) — для когорты «новый клиент», visit_seq=1. Считается по ВСЕМ визитам, включая ШАА (realt_metrics_by_month пересчитывает свой собственный seq после исключения ШАА — см. его комментарии).';


-- 2026-09-19: убран лишний JOIN на «когда-либо ШАА» (та же ошибка, что была
-- в realt_visits_categorized) — department уже есть в каждой строке
-- realt_payroll за ЕЁ СОБСТВЕННЫЙ период, доп. связка по employee_id без
-- учёта месяца была не нужна и вносила ту же ретроактивную ошибку.
CREATE OR REPLACE VIEW realt_payroll_categorized AS
SELECT
    toDateTime(toStartOfMonth(p.period)) + INTERVAL 12 HOUR AS month,
    nullIf(p.employee_id, '')                                AS employee_id,
    multiIf(p.department = 'ШАА', 'ФОТ ШАА', p.role)        AS role_group,
    p.pay_type                                               AS pay_type,
    p.accrued_total                                          AS accrued_total,
    p.ndfl                                                   AS ndfl,
    p.contributions                                          AS contributions
FROM realt_payroll p
WHERE p.period IS NOT NULL;

ALTER TABLE realt_payroll_categorized COMMENT COLUMN month 'Месяц начисления, время 12:00 (см. realt_metrics_by_month.month).';
ALTER TABLE realt_payroll_categorized COMMENT COLUMN role_group 'department=ШАА (СВОЕЙ строки, т.е. за этот же период) перекрывает исходный role.';


CREATE OR REPLACE VIEW realt_doctor_month AS
WITH visit_agg AS (
    SELECT
        month, employee_id, doctor_name, role_group,
        sum(amount)                              AS revenue,
        count()                                  AS visits,
        uniqExact(card_number)                   AS clients,
        uniqExactIf(card_number, visit_seq = 1)  AS new_clients
    FROM realt_visits_categorized
    GROUP BY month, employee_id, doctor_name, role_group
),
payroll_agg AS (
    SELECT
        month, employee_id, any(role_group) AS role_group,
        sum(accrued_total)                                            AS fot,
        sumIf(accrued_total, pay_type = 'Проценты')                   AS fot_pct,
        sumIf(accrued_total, pay_type IN ('Оклад','Бонус'))           AS fot_oklad,
        sum(coalesce(ndfl, 0) + coalesce(contributions, 0))           AS fot_taxes
    FROM realt_payroll_categorized
    GROUP BY month, employee_id
)
SELECT
    coalesce(v.month, p.month)                    AS month,
    coalesce(v.employee_id, p.employee_id)        AS employee_id,
    coalesce(v.doctor_name, dn.full_name)         AS doctor_name,
    coalesce(v.role_group, p.role_group)          AS role_group,
    v.revenue                                     AS revenue,
    v.visits                                      AS visits,
    v.clients                                     AS clients,
    v.new_clients                                 AS new_clients,
    p.fot                                         AS fot,
    p.fot_pct                                     AS fot_pct,
    p.fot_oklad                                   AS fot_oklad,
    p.fot_taxes                                   AS fot_taxes,
    v.revenue / nullIf(v.visits, 0)               AS avg_check,
    p.fot / nullIf(v.visits, 0)                   AS fot_per_visit,
    p.fot / nullIf(v.clients, 0)                  AS fot_per_client,
    v.revenue - p.fot + p.fot_taxes               AS profit_after_fot
FROM visit_agg v
FULL OUTER JOIN payroll_agg p ON v.month = p.month AND v.employee_id = p.employee_id
LEFT JOIN (SELECT employee_id, full_name FROM realt_employees FINAL WHERE full_name IS NOT NULL) dn
    ON coalesce(v.employee_id, p.employee_id) = dn.employee_id
ORDER BY month, employee_id;

ALTER TABLE realt_doctor_month COMMENT COLUMN fot_per_visit 'ФОТ ЭТОГО врача за месяц / визиты ЭТОГО врача за месяц — корректно на уровне одного врача (не средняя по больнице).';
ALTER TABLE realt_doctor_month COMMENT COLUMN fot_per_client 'ФОТ ЭТОГО врача за месяц / уникальные клиенты ЭТОГО врача за месяц.';
ALTER TABLE realt_doctor_month COMMENT COLUMN profit_after_fot 'Выручка врача − его ФОТ + налоги/взносы с его ФОТ (налоги обычно отрицательные — фактически вычитаются).';


CREATE OR REPLACE VIEW realt_role_month AS
WITH visit_agg AS (
    SELECT
        month, role_group,
        sum(amount)                              AS revenue,
        count()                                  AS visits,
        uniqExact(card_number)                   AS clients,
        uniqExactIf(card_number, visit_seq = 1)  AS new_clients
    FROM realt_visits_categorized
    GROUP BY month, role_group
),
payroll_agg AS (
    SELECT
        month, role_group,
        sum(accrued_total)                                            AS fot,
        sumIf(accrued_total, pay_type = 'Проценты')                   AS fot_pct,
        sumIf(accrued_total, pay_type IN ('Оклад','Бонус'))           AS fot_oklad,
        sum(coalesce(ndfl, 0) + coalesce(contributions, 0))           AS fot_taxes
    FROM realt_payroll_categorized
    GROUP BY month, role_group
)
SELECT
    coalesce(v.month, p.month)           AS month,
    coalesce(v.role_group, p.role_group) AS role_group,
    v.revenue                            AS revenue,
    v.visits                             AS visits,
    v.clients                            AS clients,
    v.new_clients                        AS new_clients,
    p.fot                                AS fot,
    p.fot_pct                            AS fot_pct,
    p.fot_oklad                          AS fot_oklad,
    p.fot_taxes                          AS fot_taxes,
    v.revenue / nullIf(v.visits, 0)      AS avg_check,
    p.fot / nullIf(v.visits, 0)          AS fot_per_visit,
    p.fot / nullIf(v.clients, 0)         AS fot_per_client,
    v.revenue - p.fot + p.fot_taxes      AS profit_after_fot
FROM visit_agg v
FULL OUTER JOIN payroll_agg p ON v.month = p.month AND v.role_group = p.role_group
ORDER BY month, role_group;

ALTER TABLE realt_role_month COMMENT COLUMN fot_per_visit 'ФОТ всех врачей этой роли за месяц / визиты, ПРИНЯТЫЕ врачами этой роли (не визиты всей клиники — отличие от старого realt_metrics_by_month).';
ALTER TABLE realt_role_month COMMENT COLUMN fot_per_client 'Аналогично fot_per_visit, но на уникального клиента этой роли. ВНИМАНИЕ: если клиент в одном месяце был и у психиатра, и у психолога, он войдёт в clients обеих ролей — это НЕ то же самое, что «уникальные клиенты клиники».';


CREATE OR REPLACE VIEW realt_metrics_by_month AS
WITH visits_seq AS (
    -- visit_seq по клиенту СРЕДИ ВИЗИТОВ БЕЗ ШАА (для new_clients/
    -- new_client_revenue — «новый клиент клиники, без учёта ШАА»).
    SELECT
        month,
        card_number,
        amount,
        row_number() OVER (PARTITION BY card_number ORDER BY visit_start) AS visit_seq
    FROM realt_visits_categorized
    WHERE role_group != 'ФОТ ШАА'
),
shaa_visits_seq AS (
    -- 2026-09-19: отдельная последовательность visit_seq ТОЛЬКО по визитам
    -- ШАА — «первый визит клиента к ШАА», независимая когорта от visits_seq
    -- выше (клиент мог быть давним клиентом клиники и при этом прийти к
    -- ШАА впервые, и наоборот).
    SELECT
        month,
        card_number,
        amount,
        row_number() OVER (PARTITION BY card_number ORDER BY visit_start) AS visit_seq
    FROM realt_visits_categorized
    WHERE role_group = 'ФОТ ШАА'
),
klientiks_m AS (
    SELECT
        month,
        sum(amount)                              AS revenue,
        count()                                  AS visits,
        uniqExact(card_number)                   AS clients,
        uniqExactIf(card_number, visit_seq = 1)  AS new_clients,
        sumIf(amount, visit_seq = 1)             AS new_client_revenue
    FROM visits_seq
    GROUP BY month
),
shaa_m AS (
    SELECT
        month,
        uniqExactIf(card_number, visit_seq = 1)  AS new_clients_shaa,
        sumIf(amount, visit_seq = 1)             AS new_client_revenue_shaa
    FROM shaa_visits_seq
    GROUP BY month
),
full_revenue_m AS (
    -- Полная выручка = ВСЕ визиты (с ШАА и без) — единственное место в этой
    -- VIEW, где ШАА не исключается.
    SELECT
        month,
        sum(amount) AS full_revenue
    FROM realt_visits_categorized
    GROUP BY month
),
rolling_m AS (
    -- 2026-09-19: «визиты новых клиентов за скользящий квартал» — по
    -- просьбе клиента. Когорта = «Новые клиенты» месяца M (см. visits_seq,
    -- БЕЗ ШАА). Для каждого такого клиента считаем ВСЕ его визиты (тоже
    -- без ШАА), которые попали в 3-месячное окно [M .. M+2 мес.] включительно
    -- (т.е. месяц привлечения + два следующих, СКОЛЬЗЯЩЕЕ окно по месяцу
    -- привлечения, а НЕ выравнивание по календарным кварталам — клиент из
    -- февраля считается за февраль-март-апрель, а не Q1/Q2).
    -- ВАЖНО: для последних 1-2 загруженных месяцев окно уходит в ещё не
    -- загруженные данные — метрика там будет ЗАНИЖЕНА не по факту, а
    -- потому что будущих визитов ещё нет в базе (см. комментарий к колонке).
    SELECT
        acquisition_month AS month,
        countIf(month >= acquisition_month AND month < acquisition_month + INTERVAL 3 MONTH) AS new_client_visits_3m
    FROM (
        SELECT
            card_number,
            month,
            min(month) OVER (PARTITION BY card_number) AS acquisition_month
        FROM visits_seq
    )
    GROUP BY acquisition_month
),
payroll_m AS (
    SELECT
        toDateTime(toStartOfMonth(period)) + INTERVAL 12 HOUR AS month,
        sum(accrued_total)                                    AS fot_total,
        sumIf(accrued_total, pay_type = 'Проценты')           AS fot_total_pct,
        sumIf(accrued_total, pay_type IN ('Оклад','Бонус'))   AS fot_total_oklad,
        sumIf(accrued_total, role = 'ФОТ Психиатры')          AS fot_psychiatrists,
        sumIf(accrued_total, role = 'ФОТ Психиатры' AND pay_type = 'Проценты')         AS fot_psychiatrists_pct,
        sumIf(accrued_total, role = 'ФОТ Психиатры' AND pay_type IN ('Оклад','Бонус')) AS fot_psychiatrists_oklad,
        sumIf(accrued_total, role = 'ФОТ Психологи')          AS fot_psychologists,
        sumIf(accrued_total, role = 'ФОТ Психологи' AND pay_type = 'Проценты')         AS fot_psychologists_pct,
        sumIf(accrued_total, role = 'ФОТ Психологи' AND pay_type IN ('Оклад','Бонус')) AS fot_psychologists_oklad,
        sumIf(accrued_total, role = 'ФОТ Администраторы')    AS fot_administrators,
        sumIf(accrued_total, role = 'ФОТ Администраторы' AND pay_type = 'Проценты')         AS fot_administrators_pct,
        sumIf(accrued_total, role = 'ФОТ Администраторы' AND pay_type IN ('Оклад','Бонус')) AS fot_administrators_oklad,
        sumIf(accrued_total, role = 'ФОТ Управление')         AS fot_management,
        sumIf(accrued_total, role = 'ФОТ Управление' AND pay_type = 'Проценты')         AS fot_management_pct,
        sumIf(accrued_total, role = 'ФОТ Управление' AND pay_type IN ('Оклад','Бонус')) AS fot_management_oklad,
        sumIf(accrued_total, role = 'ФОТ Маркетинг')          AS fot_marketing,
        sumIf(accrued_total, role = 'ФОТ Маркетинг' AND pay_type = 'Проценты')         AS fot_marketing_pct,
        sumIf(accrued_total, role = 'ФОТ Маркетинг' AND pay_type IN ('Оклад','Бонус')) AS fot_marketing_oklad,
        sumIf(accrued_total, department = 'ШАА')              AS fot_shmilovich,
        sumIf(accrued_total, department = 'ШАА' AND pay_type = 'Проценты')         AS fot_shmilovich_pct,
        sumIf(accrued_total, department = 'ШАА' AND pay_type IN ('Оклад','Бонус')) AS fot_shmilovich_oklad,
        sum(coalesce(ndfl, 0)) + sum(coalesce(contributions, 0)) AS fot_taxes,
        sumIf(coalesce(ndfl, 0) + coalesce(contributions, 0), pay_type = 'Проценты')         AS fot_taxes_pct,
        sumIf(coalesce(ndfl, 0) + coalesce(contributions, 0), pay_type IN ('Оклад','Бонус')) AS fot_taxes_oklad
    FROM realt_payroll
    WHERE period IS NOT NULL
    GROUP BY month
)
SELECT
    coalesce(k.month, p.month, f.month, s.month, r.month) AS month,
    f.full_revenue                                   AS full_revenue,
    k.revenue                                        AS revenue,
    k.visits                                         AS visits,
    k.clients                                        AS clients,
    k.new_clients                                    AS new_clients,
    s.new_clients_shaa                                AS new_clients_shaa,
    k.new_client_revenue                             AS new_client_revenue,
    s.new_client_revenue_shaa                        AS new_client_revenue_shaa,
    r.new_client_visits_3m                            AS new_client_visits_3m,
    r.new_client_visits_3m / nullIf(k.new_clients, 0) AS new_client_visits_3m_avg,
    k.revenue / nullIf(k.visits, 0)                  AS avg_check,
    p.fot_total                                      AS fot_total,
    p.fot_total_pct                                  AS fot_total_pct,
    p.fot_total_oklad                                AS fot_total_oklad,
    p.fot_psychiatrists                              AS fot_psychiatrists,
    p.fot_psychiatrists_pct                          AS fot_psychiatrists_pct,
    p.fot_psychiatrists_oklad                        AS fot_psychiatrists_oklad,
    p.fot_psychologists                              AS fot_psychologists,
    p.fot_psychologists_pct                          AS fot_psychologists_pct,
    p.fot_psychologists_oklad                        AS fot_psychologists_oklad,
    p.fot_administrators                             AS fot_administrators,
    p.fot_administrators_pct                         AS fot_administrators_pct,
    p.fot_administrators_oklad                       AS fot_administrators_oklad,
    p.fot_management                                 AS fot_management,
    p.fot_management_pct                             AS fot_management_pct,
    p.fot_management_oklad                           AS fot_management_oklad,
    p.fot_marketing                                  AS fot_marketing,
    p.fot_marketing_pct                              AS fot_marketing_pct,
    p.fot_marketing_oklad                            AS fot_marketing_oklad,
    p.fot_shmilovich                                 AS fot_shmilovich,
    p.fot_shmilovich_pct                             AS fot_shmilovich_pct,
    p.fot_shmilovich_oklad                           AS fot_shmilovich_oklad,
    p.fot_taxes                                      AS fot_taxes,
    p.fot_taxes_pct                                  AS fot_taxes_pct,
    p.fot_taxes_oklad                                AS fot_taxes_oklad,
    (p.fot_total - p.fot_shmilovich) / nullIf(k.revenue, 0) * 100  AS fot_revenue_share
FROM klientiks_m AS k
FULL OUTER JOIN payroll_m AS p ON k.month = p.month
FULL OUTER JOIN full_revenue_m AS f ON coalesce(k.month, p.month) = f.month
FULL OUTER JOIN shaa_m AS s ON coalesce(k.month, p.month, f.month) = s.month
FULL OUTER JOIN rolling_m AS r ON coalesce(k.month, p.month, f.month, s.month) = r.month
ORDER BY month;

ALTER TABLE realt_metrics_by_month COMMENT COLUMN month 'Начало месяца (визита по Клиентикс, либо начисления ФОТ, если визитов в этом месяце ещё нет — FULL OUTER JOIN, а не LEFT, иначе месяцы с ФОТ, но без визитов, молча пропадают). Время 12:00 — чтобы Report Timezone в Metabase не сдвигал 1-е число на предыдущий месяц (как в wb_metrics_by_cabinet_month).';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN full_revenue 'Полная выручка = SUM(amount) по ВСЕМ визитам месяца, включая ШАА (единственная колонка в этой VIEW, где ШАА не исключается). Добавлено 2026-09-19.';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN revenue 'Выручка = SUM(amount) по визитам месяца, БЕЗ подразделения «ШАА» (role_group=«ФОТ ШАА» в realt_visits_categorized, т.е. department=«ШАА» через realt_employees/realt_payroll — тот же ключ, что у fot_shmilovich). До 2026-09-19 исключение было текстовым (service содержит «шмил»/«онег») — переведено на единый с ФОТ ключ. Также исключены: сумма<=0, исполнитель «тест».';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN visits 'Количество визитов (строк) месяца после фильтров (без ШАА).';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN clients 'Уникальные клиенты месяца (по Номеру карты, card_number), без ШАА.';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN new_clients 'Новые клиенты (когорта): первый (среди визитов без ШАА) визит клиента пришёлся на этот месяц. visit_seq пересчитывается ПОСЛЕ исключения ШАА (не переиспользует общий visit_seq из realt_visits_categorized) — так смысл метрики не меняется, меняется только критерий исключения ШАА (было по тексту услуги, стало по department). НЕ по колонке «Количество завершённых» — она в выгрузке ненадёжна. Совпадает по величине с count(visit_seq=1) — «Кол-во 1 визитов» в Model/карточке ссылается на эту же колонку под другой подписью.';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN new_clients_shaa 'То же самое, что new_clients, но для визитов ШАА и с ОТДЕЛЬНОЙ последовательностью visit_seq по визитам ШАА (см. shaa_visits_seq) — «клиент впервые пришёл к ШАА». Добавлено 2026-09-19.';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN new_client_revenue 'Выручка с 1 визита = SUM(amount) по визитам с visit_seq=1 (тот же visit_seq, что определяет new_clients, БЕЗ ШАА) — сумма чеков именно за первое посещение новых клиентов месяца, а не вся их последующая выручка. До 2026-09-19 называлась «Выручка с первых визитов» (переименована, формула не менялась).';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN new_client_revenue_shaa 'Выручка с 1 визита ШАА = то же самое, но для визитов ШАА и с ОТДЕЛЬНОЙ последовательностью visit_seq, посчитанной только по визитам ШАА (см. shaa_visits_seq) — «клиент впервые пришёл к ШАА», независимая когорта от new_client_revenue (клиент мог годами быть клиентом клиники и прийти к ШАА впервые, и наоборот). Добавлено 2026-09-19.';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN new_client_visits_3m 'СУММА визитов (без ШАА) когорты «новые клиенты месяца M» за СКОЛЬЗЯЩЕЕ 3-месячное окно [M; M+2 мес.] включительно (месяц привлечения + 2 следующих, НЕ выравнивание по календарным кварталам). Раздел с new_clients даёт new_client_visits_3m_avg. ВАЖНО: для последних 1-2 загруженных месяцев окно уходит за пределы загруженных данных — значение занижено технически (визиты ещё не наступили/не загружены), это не падение активности клиентов. Добавлено 2026-09-19.';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN new_client_visits_3m_avg 'RATIO, НЕ СУММИРОВАТЬ ПО МЕСЯЦАМ ДЛЯ ГОДОВОГО ИТОГА: new_client_visits_3m / new_clients — среднее число визитов на одного нового клиента месяца M за первые 3 месяца после привлечения (скользящее). Годовой итог = sum(new_client_visits_3m за год) / sum(new_clients за год), НЕ sum/avg этой колонки по 12 месяцам — так посчитано в Metabase-карточке 186 (realt_monthly_metrics.sql), см. docs/formulas/realt.tex. Та же оговорка про незавершённое окно последних месяцев, что и у new_client_visits_3m.';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN avg_check 'RATIO, НЕ СУММИРОВАТЬ ПО МЕСЯЦАМ ДЛЯ ГОДОВОГО ИТОГА: средний чек = выручка / визиты (оба уже без ШАА). Годовой средний чек = sum(revenue за год) / sum(visits за год), НЕ sum/avg этой колонки по 12 месяцам (это дало бы сумму разных средних, бессмысленную величину) — правильная формула считается в Metabase-карточке 186 (realt_monthly_metrics.sql), см. docs/formulas/realt.tex, раздел «"За год" для ratio-метрик».';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_total 'ФОТ всего за месяц = SUM(«Начислено ИТОГО») по всем ролям (из realt_payroll). ТРЕБУЕТ СВЕРКИ: начислено vs к оплате.';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_total_pct 'ФОТ всего, только строки с pay_type=«Проценты».';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_total_oklad 'ФОТ всего, только строки с pay_type IN («Оклад»,«Бонус»).';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_psychiatrists 'ФОТ роли «Психиатры» (Начислено ИТОГО).';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_psychiatrists_pct 'ФОТ роли «Психиатры», pay_type=«Проценты».';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_psychiatrists_oklad 'ФОТ роли «Психиатры», pay_type IN («Оклад»,«Бонус»).';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_psychologists 'ФОТ роли «Психологи» (Начислено ИТОГО).';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_psychologists_pct 'ФОТ роли «Психологи», pay_type=«Проценты».';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_psychologists_oklad 'ФОТ роли «Психологи», pay_type IN («Оклад»,«Бонус»).';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_administrators 'ФОТ роли «Администраторы» (Начислено ИТОГО).';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_administrators_pct 'ФОТ роли «Администраторы», pay_type=«Проценты».';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_administrators_oklad 'ФОТ роли «Администраторы», pay_type IN («Оклад»,«Бонус»).';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_management 'ФОТ роли «Управление» (Начислено ИТОГО).';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_management_pct 'ФОТ роли «Управление», pay_type=«Проценты».';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_management_oklad 'ФОТ роли «Управление», pay_type IN («Оклад»,«Бонус»).';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_marketing 'ФОТ роли «Маркетинг» (Начислено ИТОГО).';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_marketing_pct 'ФОТ роли «Маркетинг», pay_type=«Проценты».';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_marketing_oklad 'ФОТ роли «Маркетинг», pay_type IN («Оклад»,«Бонус»).';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_shmilovich 'ФОТ подразделения «ШАА» (department=«ШАА», Начислено ИТОГО) — В ТЕКУЩЕМ СОСТАВЕ ДАННЫХ это Шмилович + администратор(ы)/психиатр, числящиеся в ШАА (шире, чем «строго Шмилович» по role). С 2026-09-19 revenue исключает ШАА по тому же ключу (см. комментарий к revenue) — раньше ключи расходились (текст услуги vs department).';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_shmilovich_pct 'ФОТ подразделения «ШАА», pay_type=«Проценты».';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_shmilovich_oklad 'ФОТ подразделения «ШАА», pay_type IN («Оклад»,«Бонус»).';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_taxes 'Налоги/взносы с ФОТ = SUM(НДФЛ)+SUM(взносы), значения из выгрузки обычно отрицательные (удержания).';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_taxes_pct 'Налоги/взносы с ФОТ, pay_type=«Проценты».';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_taxes_oklad 'Налоги/взносы с ФОТ, pay_type IN («Оклад»,«Бонус»).';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_revenue_share 'Доля ФОТ/Выручка, % = (fot_total - fot_shmilovich) / revenue * 100. И revenue, и fot_shmilovich теперь исключают ШАА по одному и тому же ключу (department=«ШАА»), fot_total при этом остаётся полным.';


CREATE VIEW IF NOT EXISTS realt_revenue_by_service AS
SELECT
    toDateTime(toStartOfMonth(visit_start)) + INTERVAL 12 HOUR AS month,
    service                                                     AS service,
    sum(amount)                                                 AS revenue,
    count()                                                     AS visits,
    sum(amount) / nullIf(count(), 0)                            AS avg_check
FROM klientiks_operations
WHERE amount > 0
  AND visit_start IS NOT NULL
  AND positionCaseInsensitiveUTF8(service, 'шмил') = 0
  AND positionCaseInsensitiveUTF8(service, 'онег') = 0
  AND positionCaseInsensitiveUTF8(doctor, 'тест') = 0
GROUP BY month, service
ORDER BY month, revenue DESC;

ALTER TABLE realt_revenue_by_service COMMENT COLUMN month 'Начало месяца визита, время 12:00 (см. realt_metrics_by_month.month).';
ALTER TABLE realt_revenue_by_service COMMENT COLUMN service 'Название услуги (как в Клиентикс).';
ALTER TABLE realt_revenue_by_service COMMENT COLUMN revenue 'Выручка по услуге за месяц = SUM(amount). ВНИМАНИЕ: исключение ШАА здесь ВСЁ ЕЩЁ текстовое (service содержит «шмил»/«онег») — НЕ переведено на department=«ШАА», в отличие от realt_metrics_by_month (см. историю 2026-09-19 в шапке файла). Разъехавшиеся цифры между этой VIEW и realt_metrics_by_month — ожидаемо, пока не выровняем и эту.';
ALTER TABLE realt_revenue_by_service COMMENT COLUMN visits 'Количество визитов по услуге за месяц.';
ALTER TABLE realt_revenue_by_service COMMENT COLUMN avg_check 'Средний чек по услуге = выручка / визиты.';


-- realt_expenses_by_month — «Остальные расходы» по типу статьи помесячно (из
-- realt_expenses, вкладка «Остальные расходы»). Строка = (месяц, expense_type).
-- Набор конкретных статей 2025≠2026, поэтому группируем по типу. Суммы
-- отрицательные (расход). ШАА (Шмилович): даём и полную сумму, и без ШАА —
-- чтобы дашборд мог показывать «с/без Шмиловича» единообразно с выручкой.
CREATE VIEW IF NOT EXISTS realt_expenses_by_month AS
SELECT
    toDateTime(toStartOfMonth(period)) + INTERVAL 12 HOUR AS month,
    coalesce(expense_type, 'Прочее')                      AS expense_type,
    sum(realt_expenses.amount)                            AS amount,
    sumIf(realt_expenses.amount, is_shaa = 0)             AS amount_ex_shaa,
    count()                                               AS articles
FROM realt_expenses
WHERE period IS NOT NULL
GROUP BY month, expense_type
ORDER BY month, expense_type;

ALTER TABLE realt_expenses_by_month COMMENT COLUMN month 'Начало месяца расхода, время 12:00 (см. realt_metrics_by_month.month — против сдвига Report Timezone в Metabase).';
ALTER TABLE realt_expenses_by_month COMMENT COLUMN expense_type 'Группа/тип статьи (строка «Дата/Тип» вкладки): Аренда+коммуналка/Налоги ФОТ/Санпэдрежим/… NULL→«Прочее».';
ALTER TABLE realt_expenses_by_month COMMENT COLUMN amount 'Сумма расходов типа за месяц = SUM(amount), обычно отрицательная. Включает ШАА (Шмилович).';
ALTER TABLE realt_expenses_by_month COMMENT COLUMN amount_ex_shaa 'То же без статей Шмиловича (is_shaa=0) — для среза «без Шмиловича», согласованного с выручкой.';
ALTER TABLE realt_expenses_by_month COMMENT COLUMN articles 'Сколько статей-столбцов этого типа попало в месяц (диагностика).';


-- realt_pl_by_group_month — P&L по группам статей (Помещение/Маркетинг/
-- Административные + внегрупповые) помесячно, из «Расчетного счета»,
-- «Наличных» и «Начислений» (realt_bank_account/realt_cash/realt_accruals),
-- плюс ФОТ+налоги Маркетинга/Управления из realt_payroll (переезжают в
-- соответствующую группу, а не остаются отдельной строкой «ФОТ»).
--
-- 2026-09-17: вынесено сюда из двух мест, где было продублировано дословно
-- (Metabase Model 178 «Реальт расходы по месяцам» и карточка 179 «Таблица -
-- Реальт - Расходы по группам (long)») — обе стали тонкими обёртками поверх
-- этой VIEW. Список статей (24 шт.) — тот же белый список, что был в обеих
-- копиях; расширять его нужно только здесь.
CREATE OR REPLACE VIEW realt_pl_by_group_month AS
WITH articles AS (
    SELECT arrayJoin([
        'Аренда - 2 этаж', 'Ком услуги - 2 этаж', 'Санпэдрежим, охрана труда - 2 этаж',
        'Аренда - 3 этаж', 'Ком услуги - 3 этаж', 'Санпэдрежим, охрана труда - 3 этаж',
        'Аренда - ШАА', 'Ком услуги - ШАА', 'Санпэдрежим, охрана труда - ШАА',
        'Телефония, связь, боты', 'Рекламный бюджет общий', 'Маркетинговые подрядчики',
        'Сервисы и подписки', 'Интернет, телефония, почта', 'Ремонт / Оборудование / Мебель',
        'Канцелярия, хоз расходы', 'Аутсорс, консалтинг, юристы', 'Мероприятия, обучения, подарки',
        'Банковские услуги', 'Прочие админ расходы', 'Прочие доходы', 'Проценты по кредитам',
        'Налог на прибыль / УСН', 'Амортизация'
    ]) AS article
),
-- 2026-09-19: expense_combined получил колонку floor_tag (realt_bank_account/
-- realt_cash.project, realt_accruals.tag — три РАЗНЫХ поля с одним смыслом:
-- «этаж/направление внутри Реальта» — 2 этаж/3 этаж/ШАА/АПДШ/Шмилович
-- личное). Найдено при разборе с владельцем: «АПДШ» (отдельное
-- направление/юрлицо, не клиника Реальт) и «Шмилович личное» (личные
-- расходы) утекали в статьи P&L-whitelist наравне с клиникой — например,
-- «Банковские услуги»/«Аутсорс, консалтинг, юристы»/«Налог на прибыль /
-- УСН» содержали строки с этими тегами (проверено на проде: ~2.9 млн ₽
-- АПДШ + ~21 тыс ₽ Шмилович личное за 2026 год только в этих трёх
-- статьях). ВСЕГДА исключаем оба тега — они не относятся к клинике вообще
-- (не то же самое, что тумблер «Учитывать ШАА», который относится к
-- подразделению КЛИНИКИ, просто выделенному в собственный P&L-срез).
-- ШАА при этом оставляем видимым — is_shaa ниже позволяет consumer'ам
-- (эта VIEW уже не даёт параметров) агрегировать amount/amount_ex_shaa
-- по тому же принципу, что и realt_expenses_by_month.amount_ex_shaa.
--
-- 2026-09-19 (второй фикс тем же вечером, по объяснению владельца):
-- realt_bank_account участвует в P&L ТОЛЬКО строками, где accrual_date
-- заполнена (раньше был fallback на operation_date через coalesce — из-за
-- него P&L задваивал часть расходов). Смысл: «Начисления» — это и есть
-- разбивка реальных денежных операций по периодам/суммам; если по строке
-- Р/с дата начисления не проставлена, эта операция ЕЩЁ БУДЕТ учтена (в
-- других месяцах/суммах) через отдельные строки realt_accruals —
-- например, лицензия/подписка на 210->300 тыс ₽ разово в Р/с (без
-- accrual_date) одновременно даёт 6 строк в Начислениях по 1/6 суммы на
-- каждый месяц вперёд (проверено на реальных парах: Понамарёв/
-- «ПрофитПросто», Ваззап, Яндекс 360, СКБ Контур, Клиентикс ERP,
-- 1С:Фреш, АДВЕРТМЕД/Битрикс — во всех Р/с-сумма делится ровно на N
-- Начисления-строк по N месяцам). Без этого фильтра сумма считалась и
-- целиком в Р/с, и ещё раз размазанной в Начислениях.
--
-- realt_cash СОЗНАТЕЛЬНО оставлен на старом coalesce(accrual_date,
-- operation_date) — проверено эмпирически 2026-09-19: у этой таблицы
-- accrual_date не заполнена НИ РАЗУ (0 из 256 строк за всю историю, не
-- только 2026 год) — «Наличные» просто не пользуются этой колонкой,
-- задвоения с realt_accruals для неё не нашли (мелкие валютные списания
-- типа Pixelcut/Gamma.app/Combot/Freepik — легитимные разовые траты без
-- пары в Начислениях). Если бы применили то же правило к Наличным, они бы
-- целиком выпали из P&L: пробовали — сверка с клиентской таблицей стала
-- ХУЖЕ (март «Телефония, связь, боты» ушёл с верных 73 807 ₽ на заниженные
-- 61 872 ₽ — ровно на сумму этих мелких трат). realt_accruals по-прежнему
-- берёт coalesce(accrual_date, operation_date) — эта вкладка по смыслу и
-- есть источник дат начисления, fallback здесь не создаёт дублей (все
-- находки сверены с клиентской «Чистой прибылью» 2026-09-19 — см.
-- docs/formulas/realt.tex).
expense_combined AS (
    SELECT
        toStartOfMonth(accrual_date) AS month,
        pl_article AS article,
        coalesce(accrual_amount, amount_signed) AS amount,
        project AS floor_tag
    FROM realt_bank_account
    WHERE pl_article IN (SELECT article FROM articles)
      AND accrual_date IS NOT NULL
      AND ( project IS NULL OR project NOT IN ('АПДШ', 'Шмилович личное') )

    UNION ALL

    SELECT
        toStartOfMonth(coalesce(accrual_date, operation_date)) AS month,
        pl_article AS article,
        coalesce(accrual_amount, amount) AS amount,
        project AS floor_tag
    FROM realt_cash
    WHERE pl_article IN (SELECT article FROM articles)
      AND ( project IS NULL OR project NOT IN ('АПДШ', 'Шмилович личное') )

    UNION ALL

    SELECT
        toStartOfMonth(coalesce(accrual_date, operation_date)) AS month,
        pl_article AS article,
        coalesce(accrual_amount, amount) AS amount,
        tag AS floor_tag
    FROM realt_accruals
    WHERE pl_article IN (SELECT article FROM articles)
      AND ( tag IS NULL OR tag NOT IN ('АПДШ', 'Шмилович личное') )
),
payroll_extra AS (
    SELECT
        toStartOfMonth(period) AS month,
        role,
        -sum(accrued_total) AS fot_amount,
        sum(coalesce(ndfl, 0)) AS ndfl_amount,
        sum(coalesce(contributions, 0)) AS contrib_amount
    FROM realt_payroll
    WHERE role IN ('ФОТ Маркетинг', 'ФОТ Управление') AND period IS NOT NULL
    GROUP BY month, role
),
rows_unified AS (
    -- Помещение
    SELECT 'Помещение' AS grp, article AS item, month, amount AS value,
           (floor_tag = 'ШАА') AS is_shaa
    FROM expense_combined
    WHERE article IN (
        'Аренда - 2 этаж', 'Ком услуги - 2 этаж', 'Санпэдрежим, охрана труда - 2 этаж',
        'Аренда - 3 этаж', 'Ком услуги - 3 этаж', 'Санпэдрежим, охрана труда - 3 этаж',
        'Аренда - ШАА', 'Ком услуги - ШАА', 'Санпэдрежим, охрана труда - ШАА'
    )

    UNION ALL
    -- Маркетинг: статьи PL
    SELECT 'Маркетинг', article, month, amount, (floor_tag = 'ШАА')
    FROM expense_combined
    WHERE article IN ('Телефония, связь, боты', 'Рекламный бюджет общий', 'Маркетинговые подрядчики')

    UNION ALL
    -- Маркетинг: ФОТ + налоги (переехали из ФОТ-строк) — is_shaa=0, у
    -- payroll_extra нет department-разреза (см. комментарий к сигнатуре
    -- этой CTE в разделе поддержки документа)
    SELECT 'Маркетинг', 'ФОТ Маркетинг', month, fot_amount, 0
    FROM payroll_extra WHERE role = 'ФОТ Маркетинг'

    UNION ALL
    SELECT 'Маркетинг', 'Взносы и НДФЛ ФОТ Маркетинг', month, ndfl_amount + contrib_amount, 0
    FROM payroll_extra WHERE role = 'ФОТ Маркетинг'

    UNION ALL
    -- Административные: ФОТ Управление + отдельно НДФЛ и Взносы
    SELECT 'Административные', 'ФОТ Управление', month, fot_amount, 0
    FROM payroll_extra WHERE role = 'ФОТ Управление'

    UNION ALL
    SELECT 'Административные', 'НДФЛ - Управление', month, ndfl_amount, 0
    FROM payroll_extra WHERE role = 'ФОТ Управление'

    UNION ALL
    SELECT 'Административные', 'Взносы ФОТ - Управление', month, contrib_amount, 0
    FROM payroll_extra WHERE role = 'ФОТ Управление'

    UNION ALL
    -- Административные: остальные статьи PL
    SELECT 'Административные', article, month, amount, (floor_tag = 'ШАА')
    FROM expense_combined
    WHERE article IN (
        'Сервисы и подписки', 'Интернет, телефония, почта', 'Ремонт / Оборудование / Мебель',
        'Канцелярия, хоз расходы', 'Аутсорс, консалтинг, юристы', 'Мероприятия, обучения, подарки',
        'Банковские услуги', 'Прочие админ расходы'
    )

    UNION ALL
    -- Внегрупповые статьи: группа = сама статья (не объединяются ни во что)
    SELECT article, article, month, amount, (floor_tag = 'ШАА')
    FROM expense_combined
    WHERE article IN ('Прочие доходы', 'Проценты по кредитам', 'Налог на прибыль / УСН', 'Амортизация')
)
SELECT
    grp                                   AS group_name,
    item                                  AS article,
    toDateTime(month) + INTERVAL 12 HOUR  AS month,
    sum(value)                            AS amount,
    sumIf(value, NOT is_shaa)             AS amount_ex_shaa
FROM rows_unified
WHERE month IS NOT NULL
GROUP BY grp, item, month
ORDER BY grp, item, month;

ALTER TABLE realt_pl_by_group_month COMMENT COLUMN group_name 'Группа P&L: Помещение / Маркетинг / Административные, либо сама статья для внегрупповых строк (Прочие доходы, Проценты по кредитам, Налог на прибыль / УСН, Амортизация).';
ALTER TABLE realt_pl_by_group_month COMMENT COLUMN article 'Статья расхода (или «ФОТ Маркетинг»/«Взносы и НДФЛ ФОТ Маркетинг»/«ФОТ Управление»/«НДФЛ - Управление»/«Взносы ФОТ - Управление» для строк, пришедших из realt_payroll).';
ALTER TABLE realt_pl_by_group_month COMMENT COLUMN month 'Начало месяца операции, время 12:00 (см. realt_metrics_by_month.month — против сдвига Report Timezone в Metabase).';
ALTER TABLE realt_pl_by_group_month COMMENT COLUMN amount 'Сумма за месяц по статье = SUM(amount) из объединения realt_bank_account/realt_cash/realt_accruals (метод начисления, если есть, иначе кассовый), либо -SUM(accrued_total)/НДФЛ+взносы из realt_payroll для строк ФОТ. С 2026-09-19 строки с project/tag IN (АПДШ, Шмилович личное) исключены ВСЕГДА (не клиника) — см. комментарий к expense_combined.';
ALTER TABLE realt_pl_by_group_month COMMENT COLUMN amount_ex_shaa 'То же без строк с project/tag=«ШАА» (добавлено 2026-09-19, единообразно с realt_expenses_by_month.amount_ex_shaa) — для строк из realt_payroll (ФОТ Маркетинг/Управление) всегда 0 в разрезе ШАА, department-разреза там нет.';
