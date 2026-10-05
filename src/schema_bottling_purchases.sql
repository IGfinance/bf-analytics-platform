-- Закупки материалов «Алабуга Боттлинг» — начало материальной цепочки
-- (закупка -> расход в производство -> выпуск -> продажа).
-- Источник: Document_ПоступлениеТоваровУслуг (+ табличная часть «Товары»).
-- Загрузчик — src/ingest_bottling_purchases.py (по месяцам, партиция =
-- месяц документа; перед вставкой месяц дропается — повторное проведение
-- документа в 1С меняет/убирает строки).
--
-- Одна плоская таблица: шапка продублирована в каждой строке товара.
-- НДС — как в реализации: «Сумма» строки в 1С С НДС при
-- СуммаВключаетНДС = 1 и БЕЗ НДС при 0, поэтому цена/сумма без НДС
-- считаются во VIEW, а сырые значения лежат как есть.
-- Материалы = строки со счётом учёта 10.01 (account_code); прочие
-- запасы (10.08 и т.п.) загружаются, но в цепочку не попадают.

CREATE DATABASE IF NOT EXISTS bottling;

CREATE TABLE IF NOT EXISTS bottling.purchase_lines
(
    ref_key             String,    -- Ref_Key документа поступления
    line_number         UInt32,    -- LineNumber строки «Товары»
    number              String,    -- номер документа в 1С
    date                DateTime,  -- дата документа
    posted              UInt8,
    deletion_mark       UInt8,
    supplier            String,    -- Контрагент (поставщик)
    contract            String,
    warehouse           String,    -- Склад приёмки
    incoming_number     String,    -- номер входящего документа поставщика
    amount_includes_vat UInt8,     -- СуммаВключаетНДС шапки

    nomenclature        String,    -- что куплено
    unit                String,
    quantity            Float64,
    price               Float64,   -- Цена как в 1С (с НДС или без — см. amount_includes_vat)
    raw_amount          Float64,   -- Сумма строки как в 1С
    vat_rate            String,
    vat_amount          Float64,
    account_code        String,    -- СчетУчета, код (10.01 — сырьё и материалы)

    loaded_at           DateTime DEFAULT now()
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(date)
ORDER BY (date, ref_key, line_number);

ALTER TABLE bottling.purchase_lines COMMENT COLUMN raw_amount 'Сумма строки как в 1С: при amount_includes_vat = 1 — С НДС, при 0 — БЕЗ НДС. Для анализа брать VIEW purchases (amount без НДС).';
ALTER TABLE bottling.purchase_lines COMMENT COLUMN price 'Цена как в документе 1С (с НДС или без — по amount_includes_vat). Для анализа брать purchases.price_net.';

-- Закупки материалов без НДС: цена и сумма «чистые», как стоимость в
-- 10.01. Только проведённые, неудалённые документы, счёт учёта 10.01.
CREATE OR REPLACE VIEW bottling.purchases AS
SELECT
    ref_key, line_number, number, date,
    toStartOfMonth(date)                         AS month,
    supplier, contract, warehouse, incoming_number,
    nomenclature, unit, quantity,
    vat_rate, vat_amount,
    if(amount_includes_vat = 1, raw_amount - vat_amount, raw_amount) AS amount_net,
    if(quantity != 0,
       if(amount_includes_vat = 1, raw_amount - vat_amount, raw_amount) / quantity,
       0)                                        AS price_net
FROM bottling.purchase_lines
WHERE posted = 1 AND deletion_mark = 0 AND account_code = '10.01';
