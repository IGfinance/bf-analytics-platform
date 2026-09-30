-- Возвраты от покупателей клиента Боттлинг (Document_ВозвратТоваровОтПокупателя,
-- табличная часть «Товары»). Нужны, чтобы получить «Чистую выручку» =
-- Выручка − Возвраты и сойтись с 1С: в Кт 90.01.1 возврат идёт
-- сторнирующей проводкой (январь 2026: −70 974,37 ₽ с НДС).
--
-- Сумма строки: при СуммаВключаетНДС = 1 она УЖЕ с НДС, при 0 — без НДС
-- (так же, как у realization_items — проверено сверкой с ОСВ по счёту 90.01
-- 2026-09-30). Во VIEW returns_net сумма приводится к БЕЗ НДС.
CREATE TABLE IF NOT EXISTS bottling.returns
(
    ref_key              String,
    line_number          UInt32,
    number               String,
    date                 DateTime,
    posted               UInt8,
    deletion_mark        UInt8,
    operation            String,    -- ВидОперации
    counterparty         String,
    amount_includes_vat  UInt8,     -- СуммаВключаетНДС шапки
    document_amount      Float64,   -- СуммаДокумента (всегда с НДС)
    nomenclature_key     String,
    nomenclature         String,
    quantity             Float64,
    amount               Float64,   -- Сумма строки (с НДС, если amount_includes_vat = 1)
    vat_amount           Float64,
    loaded_at            DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
PARTITION BY toYYYYMM(date)
ORDER BY (ref_key, line_number);

-- Проведённые, не удалённые возвраты; amount — БЕЗ НДС, положительное число
-- (вычитается из выручки), amount_with_vat — с НДС (сверка с Кт 90.01.1).
-- ВАЖНО: внутренний подзапрос переименовывает исходную колонку в raw_amount —
-- в ClickHouse псевдоним `AS amount` в том же SELECT перекрывает колонку
-- `amount` во всех остальных выражениях (первая версия этого VIEW из-за этого
-- считала amount_with_vat от уже очищенной от НДС суммы).
CREATE OR REPLACE VIEW bottling.returns_net AS
SELECT
    ref_key, number, date, toStartOfMonth(date) AS month, counterparty,
    line_number, nomenclature_key, nomenclature, quantity,
    if(amount_includes_vat = 1, raw_amount - vat_amount, raw_amount) AS amount,
    if(amount_includes_vat = 1, raw_amount, raw_amount + vat_amount) AS amount_with_vat
FROM
(
    SELECT ref_key, number, date, counterparty, line_number, nomenclature_key, nomenclature, quantity,
           amount_includes_vat, vat_amount, amount AS raw_amount
    FROM bottling.returns FINAL
    WHERE posted = 1 AND deletion_mark = 0
);
