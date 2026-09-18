-- Семантический слой метрик Реальта (Клиника) — формулы считаются здесь один
-- раз, Metabase Model становится тонкой обёрткой (см. architecture-standarts.md,
-- «Семантический слой для AI-бота», golden example wb_metrics_by_cabinet_month).
--
-- VIEW:
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
-- выручка/визиты; исключаются нулевые суммы, услуги Шмиловича/Онегиной и
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
CREATE OR REPLACE VIEW realt_metrics_by_month AS
WITH visits AS (
    SELECT
        card_number,
        toStartOfMonth(visit_start) AS m,
        amount,
        row_number() OVER (PARTITION BY card_number ORDER BY visit_start) AS visit_seq
    FROM klientiks_operations
    WHERE amount > 0
      AND visit_start IS NOT NULL
      AND card_number != ''
      AND positionCaseInsensitiveUTF8(service, 'шмил') = 0
      AND positionCaseInsensitiveUTF8(service, 'онег') = 0
      AND positionCaseInsensitiveUTF8(doctor, 'тест') = 0
),
klientiks_m AS (
    SELECT
        toDateTime(m) + INTERVAL 12 HOUR AS month,
        sum(amount)                              AS revenue,
        count()                                  AS visits,
        uniqExact(card_number)                   AS clients,
        uniqExactIf(card_number, visit_seq = 1)  AS new_clients,
        sumIf(amount, visit_seq = 1)             AS new_client_revenue
    FROM visits
    GROUP BY m
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
    coalesce(k.month, p.month)                       AS month,
    k.revenue                                        AS revenue,
    k.visits                                         AS visits,
    k.clients                                        AS clients,
    k.new_clients                                    AS new_clients,
    k.new_client_revenue                             AS new_client_revenue,
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
ORDER BY month;

ALTER TABLE realt_metrics_by_month COMMENT COLUMN month 'Начало месяца (визита по Клиентикс, либо начисления ФОТ, если визитов в этом месяце ещё нет — FULL OUTER JOIN, а не LEFT, иначе месяцы с ФОТ, но без визитов, молча пропадают). Время 12:00 — чтобы Report Timezone в Metabase не сдвигал 1-е число на предыдущий месяц (как в wb_metrics_by_cabinet_month).';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN revenue 'Выручка = SUM(amount) по визитам месяца. Исключены: сумма<=0, услуги Шмиловича/Онегиной, исполнитель «тест».';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN visits 'Количество визитов (строк) месяца после фильтров.';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN clients 'Уникальные клиенты месяца (по Номеру карты, card_number).';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN new_clients 'Новые клиенты (когорта): первый визит клиента пришёлся на этот месяц. Считается по вычисленному номеру визита (row_number по card_number), НЕ по колонке «Количество завершённых» — она в выгрузке ненадёжна.';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN new_client_revenue 'Выручка с первых визитов = SUM(amount) по визитам с visit_seq=1 (тот же visit_seq, что определяет new_clients) — сумма чеков именно за первое посещение новых клиентов месяца, а не вся их последующая выручка.';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN avg_check 'Средний чек = выручка / визиты.';
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
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_shmilovich 'ФОТ подразделения «ШАА» (department=«ШАА», Начислено ИТОГО) — В ТЕКУЩЕМ СОСТАВЕ ДАННЫХ это Шмилович + администратор(ы)/психиатр, числящиеся в ШАА (шире, чем «строго Шмилович» по role). Изменено 2026-09-17, было role=«ФОТ Шмилович». Внимание: выручка (revenue) Шмиловича НЕ включает, а этот ФОТ — да (см. fot_revenue_share).';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_shmilovich_pct 'ФОТ подразделения «ШАА», pay_type=«Проценты».';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_shmilovich_oklad 'ФОТ подразделения «ШАА», pay_type IN («Оклад»,«Бонус»).';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_taxes 'Налоги/взносы с ФОТ = SUM(НДФЛ)+SUM(взносы), значения из выгрузки обычно отрицательные (удержания).';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_taxes_pct 'Налоги/взносы с ФОТ, pay_type=«Проценты».';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_taxes_oklad 'Налоги/взносы с ФОТ, pay_type IN («Оклад»,«Бонус»).';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_revenue_share 'Доля ФОТ/Выручка, % = (fot_total - fot_shmilovich) / revenue * 100. ФОТ подразделения ШАА исключён из числителя, т.к. revenue тоже без Шмиловича/Онегиной (согласовано). fot_total при этом остаётся полным.';


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
ALTER TABLE realt_revenue_by_service COMMENT COLUMN revenue 'Выручка по услуге за месяц = SUM(amount). Фильтры те же, что в realt_metrics_by_month.';
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
expense_combined AS (
    SELECT
        toStartOfMonth(coalesce(accrual_date, operation_date)) AS month,
        pl_article AS article,
        coalesce(accrual_amount, amount_signed) AS amount
    FROM realt_bank_account
    WHERE pl_article IN (SELECT article FROM articles)

    UNION ALL

    SELECT
        toStartOfMonth(coalesce(accrual_date, operation_date)) AS month,
        pl_article AS article,
        coalesce(accrual_amount, amount) AS amount
    FROM realt_cash
    WHERE pl_article IN (SELECT article FROM articles)

    UNION ALL

    SELECT
        toStartOfMonth(coalesce(accrual_date, operation_date)) AS month,
        pl_article AS article,
        coalesce(accrual_amount, amount) AS amount
    FROM realt_accruals
    WHERE pl_article IN (SELECT article FROM articles)
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
    SELECT 'Помещение' AS grp, article AS item, month, amount AS value
    FROM expense_combined
    WHERE article IN (
        'Аренда - 2 этаж', 'Ком услуги - 2 этаж', 'Санпэдрежим, охрана труда - 2 этаж',
        'Аренда - 3 этаж', 'Ком услуги - 3 этаж', 'Санпэдрежим, охрана труда - 3 этаж',
        'Аренда - ШАА', 'Ком услуги - ШАА', 'Санпэдрежим, охрана труда - ШАА'
    )

    UNION ALL
    -- Маркетинг: статьи PL
    SELECT 'Маркетинг', article, month, amount
    FROM expense_combined
    WHERE article IN ('Телефония, связь, боты', 'Рекламный бюджет общий', 'Маркетинговые подрядчики')

    UNION ALL
    -- Маркетинг: ФОТ + налоги (переехали из ФОТ-строк)
    SELECT 'Маркетинг', 'ФОТ Маркетинг', month, fot_amount
    FROM payroll_extra WHERE role = 'ФОТ Маркетинг'

    UNION ALL
    SELECT 'Маркетинг', 'Взносы и НДФЛ ФОТ Маркетинг', month, ndfl_amount + contrib_amount
    FROM payroll_extra WHERE role = 'ФОТ Маркетинг'

    UNION ALL
    -- Административные: ФОТ Управление + отдельно НДФЛ и Взносы
    SELECT 'Административные', 'ФОТ Управление', month, fot_amount
    FROM payroll_extra WHERE role = 'ФОТ Управление'

    UNION ALL
    SELECT 'Административные', 'НДФЛ - Управление', month, ndfl_amount
    FROM payroll_extra WHERE role = 'ФОТ Управление'

    UNION ALL
    SELECT 'Административные', 'Взносы ФОТ - Управление', month, contrib_amount
    FROM payroll_extra WHERE role = 'ФОТ Управление'

    UNION ALL
    -- Административные: остальные статьи PL
    SELECT 'Административные', article, month, amount
    FROM expense_combined
    WHERE article IN (
        'Сервисы и подписки', 'Интернет, телефония, почта', 'Ремонт / Оборудование / Мебель',
        'Канцелярия, хоз расходы', 'Аутсорс, консалтинг, юристы', 'Мероприятия, обучения, подарки',
        'Банковские услуги', 'Прочие админ расходы'
    )

    UNION ALL
    -- Внегрупповые статьи: группа = сама статья (не объединяются ни во что)
    SELECT article, article, month, amount
    FROM expense_combined
    WHERE article IN ('Прочие доходы', 'Проценты по кредитам', 'Налог на прибыль / УСН', 'Амортизация')
)
SELECT
    grp                AS group_name,
    item               AS article,
    toDateTime(month) + INTERVAL 12 HOUR AS month,
    sum(value)         AS amount
FROM rows_unified
WHERE month IS NOT NULL
GROUP BY grp, item, month
ORDER BY grp, item, month;

ALTER TABLE realt_pl_by_group_month COMMENT COLUMN group_name 'Группа P&L: Помещение / Маркетинг / Административные, либо сама статья для внегрупповых строк (Прочие доходы, Проценты по кредитам, Налог на прибыль / УСН, Амортизация).';
ALTER TABLE realt_pl_by_group_month COMMENT COLUMN article 'Статья расхода (или «ФОТ Маркетинг»/«Взносы и НДФЛ ФОТ Маркетинг»/«ФОТ Управление»/«НДФЛ - Управление»/«Взносы ФОТ - Управление» для строк, пришедших из realt_payroll).';
ALTER TABLE realt_pl_by_group_month COMMENT COLUMN month 'Начало месяца операции, время 12:00 (см. realt_metrics_by_month.month — против сдвига Report Timezone в Metabase).';
ALTER TABLE realt_pl_by_group_month COMMENT COLUMN amount 'Сумма за месяц по статье = SUM(amount) из объединения realt_bank_account/realt_cash/realt_accruals (метод начисления, если есть, иначе кассовый), либо -SUM(accrued_total)/НДФЛ+взносы из realt_payroll для строк ФОТ.';


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

CREATE OR REPLACE VIEW realt_visits_categorized AS
WITH doctor_key AS (
    SELECT employee_id, full_name, upperUTF8(trim(full_name)) AS name_key
    FROM realt_employees FINAL
    WHERE full_name IS NOT NULL AND full_name != ''
),
shaa_employees AS (
    SELECT DISTINCT employee_id FROM realt_payroll WHERE department = 'ШАА'
),
employee_role AS (
    SELECT employee_id, argMax(role, period) AS role
    FROM realt_payroll
    WHERE period IS NOT NULL
    GROUP BY employee_id
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
        d.employee_id != '' AND se.employee_id != '', 'ФОТ ШАА',
        d.employee_id != '' AND er.role IS NOT NULL, er.role,
        d.employee_id != '', 'Без ФОТ-кода',
        'Не в справочнике сотрудников'
    )                                                          AS role_group,
    row_number() OVER (PARTITION BY k.card_number ORDER BY k.visit_start) AS visit_seq
FROM klientiks_operations k
LEFT JOIN doctor_key d ON upperUTF8(trim(k.doctor)) = d.name_key
LEFT JOIN shaa_employees se ON d.employee_id = se.employee_id
LEFT JOIN employee_role er ON d.employee_id = er.employee_id
WHERE k.amount > 0
  AND k.visit_start IS NOT NULL
  AND k.card_number != ''
  AND positionCaseInsensitiveUTF8(k.doctor, 'тест') = 0;

ALTER TABLE realt_visits_categorized COMMENT COLUMN month 'Начало месяца визита, время 12:00 (см. realt_metrics_by_month.month).';
ALTER TABLE realt_visits_categorized COMMENT COLUMN employee_id 'Код сотрудника (realt_employees/realt_payroll). NULL — врач не найден в справочнике сотрудников (см. role_group).';
ALTER TABLE realt_visits_categorized COMMENT COLUMN doctor_name 'ФИО врача — из справочника сотрудников, если найден, иначе как в Клиентикс (doctor).';
ALTER TABLE realt_visits_categorized COMMENT COLUMN role_group 'Категория: ФОТ Психиатры/Психологи/Администраторы/Управление/Маркетинг/ШАА (по employee_id, не по названию услуги) — либо «Без ФОТ-кода»/«Не в справочнике сотрудников» при неполноте данных.';
ALTER TABLE realt_visits_categorized COMMENT COLUMN visit_seq 'Порядковый номер визита клиента (по card_number, сортировка по дате) — для когорты «новый клиент», visit_seq=1.';


CREATE OR REPLACE VIEW realt_payroll_categorized AS
SELECT
    toDateTime(toStartOfMonth(p.period)) + INTERVAL 12 HOUR AS month,
    nullIf(p.employee_id, '')                                AS employee_id,
    multiIf(se.employee_id != '', 'ФОТ ШАА', p.role)        AS role_group,
    p.pay_type                                               AS pay_type,
    p.accrued_total                                          AS accrued_total,
    p.ndfl                                                   AS ndfl,
    p.contributions                                          AS contributions
FROM realt_payroll p
LEFT JOIN (SELECT DISTINCT employee_id FROM realt_payroll WHERE department = 'ШАА') se
    ON p.employee_id = se.employee_id
WHERE p.period IS NOT NULL;

ALTER TABLE realt_payroll_categorized COMMENT COLUMN month 'Месяц начисления, время 12:00 (см. realt_metrics_by_month.month).';
ALTER TABLE realt_payroll_categorized COMMENT COLUMN role_group 'Как в realt_visits_categorized — department=ШАА перекрывает исходный role.';


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
