-- Кредиты и займы «Алабуга Боттлинг» из 1С: тело и проценты, статус «оплачен».
--
-- ИСТОЧНИК — проводки по счетам 66.* / 67.* (краткосрочные / долгосрочные
-- кредиты и займы). В базе Боттлинга реально живут 67.03 «Долгосрочные
-- займы» (банки — АК БАРС, Промсвязьбанк, Сбербанк; МФК-фонд; займы от
-- своих компаний и физлиц) и 67.04 «Проценты по долгосрочным займам»;
-- 67.01 встречается один раз. Остальные счета группы заведены в
-- загрузчик на будущее — они пустые.
--
-- МОДЕЛЬ. Таблица credit_entries хранит НОГИ проводок: одна проводка
-- Дт 51 / Кт 67.03 даёт одну ногу (счёт 67.03, сторона «Кт»). Проводка
-- между двумя кредитными счетами (перенос долга, Дт 67.03 / Кт 67.03)
-- даёт две ноги — по одной на каждый договор. Договор и контрагент берутся
-- из субконто ноги.
--
-- СТАТУС «ОПЛАЧЕН» — расчётный, в 1С его нет: 1С не хранит график погашения,
-- есть только факты. Поэтому:
--   * ТЕЛО. Строка = получение (Кт по телу) за день по договору. Все
--     погашения договора (Дт по телу) зачитываются на получения по
--     порядку дат, самые ранние закрываются первыми (FIFO). Строка
--     «Оплачен», если закрыта целиком; «Частично оплачен» — если закрыта
--     частично; «Не оплачен» — если нет.
--   * ПРОЦЕНТЫ. То же самое: строка = начисление (Кт по процентам) за день
--     по договору, оплаты (Дт по процентам, включая удержанный НДФЛ) —
--     FIFO по датам.
--   Для кредитной линии (АК БАРС 2/25/2086: ~240 траншей и погашений)
--   FIFO даёт честный остаток договора и «какие транши ещё не закрыты»,
--   но не «чем именно платили» — платёжка в 1С к конкретному траншу не
--   привязана. Итоговый остаток договора от выбора порядка не зависит.
--
-- СТОРНО. Отрицательная сумма в Кт — это откат получения/начисления, она
-- считается погашением; отрицательная сумма в Дт — откат погашения.
--
-- ИДЕМПОТЕНТНОСТЬ: credit_entries — партиция = месяц проводки, загрузчик
-- дропает партицию перед вставкой. credit_contracts — маленький справочник,
-- upsert по ключу (удалить договоры загрузки и вставить заново).

CREATE DATABASE IF NOT EXISTS bottling;

CREATE TABLE IF NOT EXISTS bottling.credit_entries
(
    period        DateTime,   -- Period проводки
    recorder      String,     -- Recorder — GUID документа-регистратора
    recorder_type String,     -- напр. 'Document_СписаниеСРасчетногоСчета'
    line_number   UInt32,
    account       String,     -- код счёта ноги: '67.03', '67.04'
    part          String,     -- 'body' (тело: 66.01/.03, 67.01/.03 …) или 'interest' (проценты: 66.02/.04, 67.02/.04 …)
    side          String,     -- 'Дт' (погашение) / 'Кт' (получение, начисление)
    corr_account  String,     -- счёт на другой стороне проводки: '51', '91.02', '67.03', '000'
    contract_key  String,     -- GUID договора (Catalog_ДоговорыКонтрагентов)
    amount        Float64,    -- Сумма, ₽ (может быть отрицательной — сторно)
    content       String      -- Содержание (основание платежа)
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(period)
ORDER BY (contract_key, period, recorder, line_number, side);

-- Справочник договоров, встречающихся в credit_entries. Данные карточки
-- договора в 1С: ставка и срок не всегда заполнены (rate = 0 — «не задана
-- или без процентов», смотрите rate_type).
CREATE TABLE IF NOT EXISTS bottling.credit_contracts
(
    contract_key  String,
    contract      String,            -- Description: «б/н от 21.06.2024 г.»
    counterparty  String,            -- кредитор / займодавец
    kind          String,            -- ВидДоговора: 'ЗаемПолученный', 'Прочее' …
    rate          Float64,           -- ПроцентнаяСтавка, % годовых
    rate_type     String,            -- 'ФиксированнаяСтавка', 'СтавкаЦБ', 'БезНачисленияПроцентов'
    signed_at     Nullable(Date),    -- Дата договора
    term_end      Nullable(Date),    -- СрокДействия (срок возврата); NULL — не задан
    limit_amount  Float64,           -- Сумма договора, 0 — не задана
    closed        UInt8,             -- ДоговорЗакрыт
    comment       String
)
ENGINE = MergeTree
ORDER BY contract_key;

-- Тело: получения по договорам и сколько уже погашено.
CREATE OR REPLACE VIEW bottling.credit_principal AS
WITH
    flows AS (
        SELECT contract_key, period, recorder, line_number, side, corr_account, amount
        FROM bottling.credit_entries
        WHERE part = 'body'
    ),
    -- Погашено по договору всего: Дт, плюс сторно Кт (отрицательные), минус сторно Дт (внутри суммы Дт).
    repaid AS (
        SELECT contract_key,
               sumIf(amount, side = 'Дт') + sumIf(-amount, side = 'Кт' AND amount < 0) AS repaid_total
        FROM flows
        GROUP BY contract_key
    ),
    -- Получения по дням; кумулятивная сумма — для FIFO.
    receipts AS (
        SELECT contract_key,
               toDate(period) AS day,
               sum(amount) AS day_amount,
               if(countIf(corr_account IN ('50', '51', '52', '55')) > 0, 'Получен транш', 'Перенос долга') AS kind
        FROM flows
        WHERE side = 'Кт' AND amount > 0
        GROUP BY contract_key, day
    ),
    cum AS (
        SELECT contract_key, day, day_amount, kind,
               sum(day_amount) OVER (PARTITION BY contract_key ORDER BY day ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cum_amount
        FROM receipts
    )
SELECT
    cum.day AS day,
    cum.day_amount AS amount,
    cum.kind AS kind,
    c.counterparty AS counterparty,
    c.contract AS contract,
    c.rate AS rate,
    c.term_end AS term_end,
    c.closed AS contract_closed,
    round(least(cum.day_amount, greatest(0, coalesce(r.repaid_total, 0) - (cum.cum_amount - cum.day_amount))), 2) AS paid,
    round(cum.day_amount - least(cum.day_amount, greatest(0, coalesce(r.repaid_total, 0) - (cum.cum_amount - cum.day_amount))), 2) AS remaining,
    multiIf(remaining <= 0.005, 'Оплачен', paid <= 0.005, 'Не оплачен', 'Частично оплачен') AS status
FROM cum
LEFT JOIN bottling.credit_contracts AS c ON c.contract_key = cum.contract_key
LEFT JOIN repaid AS r ON r.contract_key = cum.contract_key;

-- Проценты: начисления по договорам и сколько уже оплачено.
CREATE OR REPLACE VIEW bottling.credit_interest AS
WITH
    flows AS (
        SELECT contract_key, period, recorder, line_number, side, amount
        FROM bottling.credit_entries
        WHERE part = 'interest'
    ),
    paid_sum AS (
        SELECT contract_key,
               sumIf(amount, side = 'Дт') + sumIf(-amount, side = 'Кт' AND amount < 0) AS paid_total
        FROM flows
        GROUP BY contract_key
    ),
    accruals AS (
        SELECT contract_key, toDate(period) AS day, sum(amount) AS day_amount
        FROM flows
        WHERE side = 'Кт' AND amount > 0
        GROUP BY contract_key, day
    ),
    cum AS (
        SELECT contract_key, day, day_amount,
               sum(day_amount) OVER (PARTITION BY contract_key ORDER BY day ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cum_amount
        FROM accruals
    )
SELECT
    cum.day AS day,
    cum.day_amount AS amount,
    c.counterparty AS counterparty,
    c.contract AS contract,
    c.rate AS rate,
    c.term_end AS term_end,
    c.closed AS contract_closed,
    round(least(cum.day_amount, greatest(0, coalesce(p.paid_total, 0) - (cum.cum_amount - cum.day_amount))), 2) AS paid,
    round(cum.day_amount - least(cum.day_amount, greatest(0, coalesce(p.paid_total, 0) - (cum.cum_amount - cum.day_amount))), 2) AS remaining,
    multiIf(remaining <= 0.005, 'Оплачен', paid <= 0.005, 'Не оплачен', 'Частично оплачен') AS status
FROM cum
LEFT JOIN bottling.credit_contracts AS c ON c.contract_key = cum.contract_key
LEFT JOIN paid_sum AS p ON p.contract_key = cum.contract_key;
