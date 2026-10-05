-- Остатки «Алабуга Боттлинг» на КОНЕЦ месяца из 1С: счёт 10.01 (сырьё и
-- материалы) и 43 (готовая продукция), по номенклатуре и складу.
-- Источник — AccountingRegister_Хозрасчетный/BalanceAndTurnovers (СуммаClosingBalance);
-- загрузчик src/ingest_bottling_balances.py (партиция = месяц, перед вставкой
-- дропается). Остатки — в рублях по учёту 1С.
--
-- ВАЖНО:
--   * 43 — по ПОЛНОЙ учётной себестоимости (материалы + ОПР + прочее), а не
--     только материалы: из проводок 1С слой «только материалы» по остатку не
--     выделить.
--   * Остаток закрытого месяца считается после регламентной операции. Месяц,
--     который в 1С ещё не закрыт (сентябрь 2026), — ПРЕДВАРИТЕЛЬНЫЙ: расход
--     материалов ещё не списан по стоимости, остаток 10.01 завышен.

CREATE DATABASE IF NOT EXISTS bottling;

CREATE TABLE IF NOT EXISTS bottling.balances
(
    month_end      Date,       -- последний день месяца, на который остаток
    account        String,     -- код счёта: '10.01' или '43'
    nomenclature   String,     -- субконто 1 — номенклатура
    warehouse      String,     -- субконто 3 — склад
    amount         Float64,    -- остаток, руб. (дебетовое сальдо со знаком)
    quantity       Float64,    -- остаток в натуральных единицах
    loaded_at      DateTime DEFAULT now()
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(month_end)
ORDER BY (month_end, account, nomenclature, warehouse);

-- Остатки по месяцам: month — первое число месяца остатка.
CREATE OR REPLACE VIEW bottling.balances_month AS
SELECT
    toStartOfMonth(month_end) AS month,
    sumIf(amount, account = '10.01') AS balance_materials,
    sumIf(amount, account = '43')    AS balance_goods
FROM bottling.balances
GROUP BY month;
