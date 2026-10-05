-- Материальная цепочка «Алабуга Боттлинг»:
--   закупка материала (purchases) -> расход в производство (chain_usage)
--   -> выпуск продукции (chain_output) -> продажа (chain_sales).
-- ТОЛЬКО МАТЕРИАЛЫ (Дт 20.01 / Кт 10.01): без ОПР, зарплаты и прочих
-- прямых — как слой «Материалы» в подробной себестоимости.
--
-- ВСЁ, КРОМЕ ЗАКУПОК, ЕСТЬ В bottling.cost_entries — отдельной загрузки
-- производства не нужно:
--   * КОЛИЧЕСТВО материала по дням — проводки Дт 20.01 / Кт 10.01 от
--     Document_ОтчетПроизводстваЗаСмену (qty_cr; сумма в них = 0, цена
--     появляется только при закрытии месяца). Продукция — dr_ext3,
--     материал — cr_ext1.
--   * РУБЛИ — проводки Дт 20.01 / Кт 10.01 от Document_РегламентнаяОперация
--     («Корректировка стоимости списания», qty = 0) по той же паре
--     «продукция × материал» за месяц.
--   Ставка материала на продукт в месяце = рубли регламентной операции /
--   количество из отчётов. Сумма по цепочке == Дт 20.01 / Кт 10.01 из
--   регламентных операций (контроль — chain_check).
--   Прочие проводки Дт 20.01 / Кт 10.01 (ручная ОперацияБух июня — вода
--   «Святой ключ» 18,9 л на 11,47 млн, Требование-накладная) в цепочку НЕ
--   входят — это списания, они на дашборде себестоимости отдельным слоем.
-- Выпуск — Дт 43 / Кт 40 от отчётов производства (qty_dr; сумма там
-- плановая, 1 ₽/шт, не использовать).
-- Продажи — bottling.realization_revenue; материальная себестоимость
-- продажи = количество × материальная себестоимость единицы продукта в
-- месяце продажи (ставка месяца, без партий — решение владельца
-- 2026-09-30). Нет выпуска продукта в месяце продажи (товары, продажи
-- со склада прошлых месяцев) -> себестоимость 0 и has_cost = 0
-- (честный пропуск, не средние).

-- 1. Ставка материала на продукт в месяце ------------------------------
CREATE OR REPLACE VIEW bottling.chain_usage_rate AS
SELECT
    month, product, material,
    sum(qty_used)    AS qty_total,
    sum(cost_booked) AS cost_total,
    if(sum(qty_used) > 0, sum(cost_booked) / sum(qty_used), 0) AS rate
FROM
(
    SELECT
        toStartOfMonth(period) AS month,
        trimBoth(dr_ext3)      AS product,
        trimBoth(cr_ext1)      AS material,
        if(recorder_type IN ('Document_ОтчетПроизводстваЗаСмену', 'Document_ТребованиеНакладная'), qty_cr, 0) AS qty_used,
        if(recorder_type = 'Document_РегламентнаяОперация', amount, 0) AS cost_booked
    FROM bottling.cost_entries
    WHERE dr_account = '20.01' AND cr_account = '10.01'
      AND recorder_type IN ('Document_ОтчетПроизводстваЗаСмену', 'Document_ТребованиеНакладная', 'Document_РегламентнаяОперация')
)
GROUP BY month, product, material;

-- 2. Расход материалов по отчётам производства (что, куда, когда, почем) -
--   rate / cost      — как в учёте 1С (регламентная операция; 0, если 1С в
--                      этом месяце стоимость не списал — янв, фев, июнь–авг);
--   ref_price / cost_ref — СПРАВОЧНО: последняя цена закупки без НДС на дату
--                      расхода (purchases) × количество. Это не учёт, а
--                      ориентир «сколько стоил бы расход по закупке»; в итоги
--                      себестоимости не подставляется. 0 — закупок материала
--                      с начала 2026 не было (остаток прошлого года).
CREATE OR REPLACE VIEW bottling.chain_usage AS
SELECT
    u.date AS date, u.month AS month, u.recorder AS recorder,
    u.product AS product, u.material AS material,
    if(c.category != '', c.category, 'Без категории (нет в справочнике)') AS material_category,
    u.qty_used AS qty_used,
    r.rate AS rate,
    u.qty_used * r.rate AS cost,
    p.price_net AS ref_price,
    u.qty_used * p.price_net AS cost_ref
FROM
(
    SELECT
        period AS date, toStartOfMonth(period) AS month, recorder,
        trimBoth(dr_ext3) AS product, trimBoth(cr_ext1) AS material,
        sum(qty_cr) AS qty_used
    FROM bottling.cost_entries
    WHERE dr_account = '20.01' AND cr_account = '10.01'
      AND recorder_type = 'Document_ОтчетПроизводстваЗаСмену'
    GROUP BY date, month, recorder, product, material
) AS u
LEFT JOIN bottling.chain_usage_rate AS r
    ON r.month = u.month AND r.product = u.product AND r.material = u.material
LEFT JOIN
(
    SELECT trimBoth(nomenclature) AS nomenclature, any(material_category) AS category
    FROM bottling.material_folder FINAL
    GROUP BY nomenclature
) AS c ON c.nomenclature = u.material
LEFT ASOF JOIN
(
    SELECT trimBoth(nomenclature) AS material, date AS purchase_date, price_net
    FROM bottling.purchases
    WHERE quantity > 0 AND price_net > 0
) AS p ON p.material = u.material AND u.date >= p.purchase_date;

-- 3. Выпуск готовой продукции по отчётам производства -------------------
CREATE OR REPLACE VIEW bottling.chain_output AS
SELECT
    period AS date, toStartOfMonth(period) AS month, recorder,
    trimBoth(dr_ext1) AS product,
    sum(qty_dr) AS qty_out
FROM bottling.cost_entries
WHERE dr_account = '43' AND cr_account = '40'
  AND recorder_type = 'Document_ОтчетПроизводстваЗаСмену'
GROUP BY date, month, recorder, product;

-- 4. Продукт × месяц: выпуск, материальная себестоимость, на единицу ----
--   cost_material — по учёту 1С; cost_material_ref — справочно по ценам закупки.
CREATE OR REPLACE VIEW bottling.chain_product_month AS
SELECT
    o.month AS month, o.product AS product,
    o.qty_month AS qty_out,
    coalesce(c.cost_mat, 0) AS cost_material,
    if(o.qty_month > 0, coalesce(c.cost_mat, 0) / o.qty_month, 0) AS unit_material_cost,
    coalesce(f.cost_mat_ref, 0) AS cost_material_ref,
    if(o.qty_month > 0, coalesce(f.cost_mat_ref, 0) / o.qty_month, 0) AS unit_material_cost_ref
FROM (SELECT month, product, sum(qty_out) AS qty_month FROM bottling.chain_output GROUP BY month, product) AS o
LEFT JOIN (SELECT month, product, sum(cost_total) AS cost_mat
           FROM bottling.chain_usage_rate GROUP BY month, product) AS c
    ON c.month = o.month AND c.product = o.product
LEFT JOIN (SELECT month, product, sum(cost_ref) AS cost_mat_ref
           FROM bottling.chain_usage GROUP BY month, product) AS f
    ON f.month = o.month AND f.product = o.product;

-- 5. Продажи с материальной себестоимостью ------------------------------
CREATE OR REPLACE VIEW bottling.chain_sales AS
SELECT
    s.date AS date, s.month AS month, s.number AS number,
    s.counterparty AS counterparty, trimBoth(s.nomenclature) AS product,
    s.quantity AS quantity, s.unit AS unit, s.price AS price,
    s.amount AS revenue,
    p.unit_material_cost AS unit_material_cost,
    s.quantity * coalesce(p.unit_material_cost, 0) AS cost_material,
    if(coalesce(p.unit_material_cost, 0) > 0, 1, 0) AS has_cost,
    s.quantity * coalesce(p.unit_material_cost_ref, 0) AS cost_material_ref
FROM bottling.realization_revenue AS s
LEFT JOIN bottling.chain_product_month AS p
    ON p.month = s.month AND p.product = trimBoth(s.nomenclature);

-- 6. Контроль: цепочка сходится с проводками -----------------------------
--   ledger_materials   — Дт 20.01 / Кт 10.01 регламентных операций (итог месяца);
--   in_chain           — часть, у которой есть количество из отчётов (идёт в цепочку);
--   no_qty_writeoffs   — рубли без количества в отчётах (напр. июнь: соки «ДБ»,
--                        ПЛБП-000090) — в цепочку не попадают;
--   other_writeoffs    — прочие регистраторы (ручная ОперацияБух, Требование).
--   ledger_materials = in_chain + no_qty_writeoffs.
CREATE OR REPLACE VIEW bottling.chain_check AS
SELECT
    k.month AS month,
    k.ledger_materials AS ledger_materials,
    coalesce(r.in_chain, 0) AS in_chain,
    coalesce(r.no_qty, 0) AS no_qty_writeoffs,
    k.other_writeoffs AS other_writeoffs
FROM
(
    SELECT
        toStartOfMonth(period) AS month,
        sumIf(amount, recorder_type = 'Document_РегламентнаяОперация') AS ledger_materials,
        sumIf(amount, recorder_type NOT IN ('Document_РегламентнаяОперация', 'Document_ОтчетПроизводстваЗаСмену')) AS other_writeoffs
    FROM bottling.cost_entries
    WHERE dr_account = '20.01' AND cr_account = '10.01'
    GROUP BY month
) AS k
LEFT JOIN
(
    SELECT month, sumIf(cost_total, qty_total > 0) AS in_chain, sumIf(cost_total, qty_total = 0) AS no_qty
    FROM bottling.chain_usage_rate GROUP BY month
) AS r ON r.month = k.month;

-- 7. Поток материала по месяцам: закупка vs расход -----------------------
--   Остаток на начало 2026 в данных нет (ОСВ 10.01 не загружена), поэтому
--   qty_net = закуплено − израсходовано — это ИЗМЕНЕНИЕ склада материалов
--   за месяц, а не остаток.
CREATE OR REPLACE VIEW bottling.chain_material_flow AS
SELECT
    month, material,
    sum(qty_bought) AS qty_purchased, sum(amount_bought) AS amount_purchased,
    sum(qty_spent)  AS qty_consumed,  sum(cost_booked)   AS cost_consumed,
    sum(qty_bought) - sum(qty_spent) AS qty_net
FROM
(
    SELECT month, trimBoth(nomenclature) AS material,
           quantity AS qty_bought, amount_net AS amount_bought,
           0 AS qty_spent, 0 AS cost_booked
    FROM bottling.purchases
    UNION ALL
    SELECT month, material, 0, 0, qty_total, cost_total
    FROM bottling.chain_usage_rate
)
GROUP BY month, material;
