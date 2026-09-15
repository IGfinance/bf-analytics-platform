-- Семантический слой метрик Реальта (Клиника) — формулы считаются здесь один
-- раз, Metabase Model становится тонкой обёрткой (см. architecture-standarts.md,
-- «Семантический слой для AI-бота», golden example wb_metrics_by_cabinet_month).
--
-- Две VIEW:
--   realt_metrics_by_month   — одна строка = месяц (выручка/визиты/клиенты/ФОТ);
--   realt_revenue_by_service — одна строка = (месяц, услуга): выручка по услугам.
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

CREATE VIEW IF NOT EXISTS realt_metrics_by_month AS
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
        uniqExactIf(card_number, visit_seq = 1)  AS new_clients
    FROM visits
    GROUP BY m
),
payroll_m AS (
    SELECT
        toDateTime(toStartOfMonth(period)) + INTERVAL 12 HOUR AS month,
        sum(accrued_total)                                    AS fot_total,
        sumIf(accrued_total, role = 'ФОТ Психиатры')          AS fot_psychiatrists,
        sumIf(accrued_total, role = 'ФОТ Психологи')          AS fot_psychologists,
        sumIf(accrued_total, role = 'ФОТ Администраторы')     AS fot_administrators,
        sumIf(accrued_total, role = 'ФОТ Управление')         AS fot_management,
        sumIf(accrued_total, role = 'ФОТ Маркетинг')          AS fot_marketing,
        sumIf(accrued_total, role = 'ФОТ Шмилович')           AS fot_shmilovich,
        sum(coalesce(ndfl, 0)) + sum(coalesce(contributions, 0)) AS fot_taxes
    FROM realt_payroll
    WHERE period IS NOT NULL
    GROUP BY month
)
SELECT
    k.month                                          AS month,
    k.revenue                                        AS revenue,
    k.visits                                         AS visits,
    k.clients                                        AS clients,
    k.new_clients                                    AS new_clients,
    k.revenue / nullIf(k.visits, 0)                  AS avg_check,
    p.fot_total                                      AS fot_total,
    p.fot_psychiatrists                              AS fot_psychiatrists,
    p.fot_psychologists                              AS fot_psychologists,
    p.fot_administrators                             AS fot_administrators,
    p.fot_management                                 AS fot_management,
    p.fot_marketing                                  AS fot_marketing,
    p.fot_shmilovich                                 AS fot_shmilovich,
    p.fot_taxes                                      AS fot_taxes,
    (p.fot_total - p.fot_shmilovich) / nullIf(k.revenue, 0) * 100  AS fot_revenue_share
FROM klientiks_m AS k
LEFT JOIN payroll_m AS p ON k.month = p.month
ORDER BY k.month;

ALTER TABLE realt_metrics_by_month COMMENT COLUMN month 'Начало месяца визита (по visit_start), время 12:00 — чтобы Report Timezone в Metabase не сдвигал 1-е число на предыдущий месяц (как в wb_metrics_by_cabinet_month).';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN revenue 'Выручка = SUM(amount) по визитам месяца. Исключены: сумма<=0, услуги Шмиловича/Онегиной, исполнитель «тест».';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN visits 'Количество визитов (строк) месяца после фильтров.';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN clients 'Уникальные клиенты месяца (по Номеру карты, card_number).';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN new_clients 'Новые клиенты (когорта): первый визит клиента пришёлся на этот месяц. Считается по вычисленному номеру визита (row_number по card_number), НЕ по колонке «Количество завершённых» — она в выгрузке ненадёжна.';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN avg_check 'Средний чек = выручка / визиты.';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_total 'ФОТ всего за месяц = SUM(«Начислено ИТОГО») по всем ролям (из realt_payroll). ТРЕБУЕТ СВЕРКИ: начислено vs к оплате.';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_psychiatrists 'ФОТ роли «Психиатры» (Начислено ИТОГО).';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_psychologists 'ФОТ роли «Психологи» (Начислено ИТОГО).';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_administrators 'ФОТ роли «Администраторы» (Начислено ИТОГО).';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_management 'ФОТ роли «Управление» (Начислено ИТОГО).';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_marketing 'ФОТ роли «Маркетинг» (Начислено ИТОГО).';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_shmilovich 'ФОТ роли «Шмилович» (Начислено ИТОГО). Внимание: выручка (revenue) Шмиловича НЕ включает, а этот ФОТ — да (см. fot_revenue_share).';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_taxes 'Налоги/взносы с ФОТ = SUM(НДФЛ)+SUM(взносы), значения из выгрузки обычно отрицательные (удержания).';
ALTER TABLE realt_metrics_by_month COMMENT COLUMN fot_revenue_share 'Доля ФОТ/Выручка, % = (fot_total - fot_shmilovich) / revenue * 100. ФОТ Шмиловича исключён из числителя, т.к. revenue тоже без Шмиловича (согласовано). fot_total при этом остаётся полным.';


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
