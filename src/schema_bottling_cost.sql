-- Себестоимость «Алабуга Боттлинг» по месяцам — БЕЗ партионного учёта,
-- «ставка месяца», совпадающая с текущим учётом 1С (счёт 90.02.1).
--
-- ПОЧЕМУ НЕ ПАРТИИ (разведка января 2026, см. вики): 1С не считает
-- себестоимость при отгрузке — строки РеализацияТоваровУслуг проведены
-- почти на нули. Реальная себестоимость появляется при закрытии месяца
-- (Document_РегламентнаяОперация): котёл «20.01 Основное производство»
-- за месяц по номенклатурной группе делится на
--   * Дт 90.02.1 / Кт 20.01 — материалы и прямые расходы списываются в
--     себестоимость продаж СРАЗУ, минуя склад;
--   * Дт 40 → Дт 43 — на склад готовой продукции уходит только
--     общепроизводственные расходы (счёт 25), продукция на складе
--     оценена только ими;
--   * Дт 90.02.1 / Кт 43 — потом эта часть списывается при продаже.
-- Причина «материалы минуют склад» не выяснена (вопрос бухгалтеру) —
-- пока принято как есть: считаем «как в учёте».
--
-- ОДНА ТАБЛИЦА ПРОВОДОК + VIEW. Вместо выгрузки всего журнала
-- (155 тыс. проводок) хранится узкий срез — только проводки по счетам
-- себестоимости (20.*, 23.*, 25, 28, 40, 43, 90.02*) с расшифрованными
-- субконто. Слои и статьи затрат — во VIEW поверх таблицы, чтобы
-- правило менялось без перезагрузки данных.
--
-- ИДЕМПОТЕНТНОСТЬ: партиция = месяц проводки. Загрузчик перед вставкой
-- месяца дропает его партицию (повторное проведение регламентной
-- операции в 1С меняет/убирает строки — ReplacingMergeTree по ключу
-- строки не убрал бы «осиротевшие»).

CREATE DATABASE IF NOT EXISTS bottling;

CREATE TABLE IF NOT EXISTS bottling.cost_entries
(
    period          DateTime,   -- Period проводки
    recorder        String,     -- Recorder — GUID документа-регистратора
    recorder_type   String,     -- тип регистратора, напр. 'Document_РегламентнаяОперация'
    line_number     UInt32,     -- номер строки в наборе записей регистратора
    dr_account      String,     -- код счёта Дт, напр. '20.01', '90.02.1'
    cr_account      String,     -- код счёта Кт
    dr_ext1         String,     -- субконто Дт 1..3, расшифрованное имя (смысл зависит от счёта — см. комментарий)
    dr_ext2         String,
    dr_ext3         String,
    cr_ext1         String,
    cr_ext2         String,
    cr_ext3         String,
    dr_subdivision  String,     -- ПодразделениеDr (имя), обычно пусто
    cr_subdivision  String,
    amount          Float64,    -- Сумма проводки, руб.
    qty_dr          Float64,    -- КоличествоDr
    qty_cr          Float64,    -- КоличествоCr
    content         String,     -- Содержание проводки

    loaded_at       DateTime DEFAULT now()
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(period)
ORDER BY (period, recorder, line_number);

ALTER TABLE bottling.cost_entries COMMENT COLUMN dr_ext1 'Субконто Дт 1. Смысл по счетам: 20.01/40/90.02.1 — номенклатурная группа; 10.01/43 — номенклатура; 25 — статья затрат.';
ALTER TABLE bottling.cost_entries COMMENT COLUMN dr_ext2 'Субконто Дт 2. 20.01 — статья затрат (Материалы, Оплата труда, Амортизация…); 40 — вид стоимости.';
ALTER TABLE bottling.cost_entries COMMENT COLUMN dr_ext3 'Субконто Дт 3. 20.01 — продукция; 10.01/43 — склад.';
ALTER TABLE bottling.cost_entries COMMENT COLUMN cr_ext1 'Субконто Кт 1 — те же смыслы по счетам, что у dr_ext1.';
ALTER TABLE bottling.cost_entries COMMENT COLUMN amount 'Сумма проводки в рублях. Сторнирующие/возвратные проводки — с минусом, суммировать как есть.';

-- ---------------------------------------------------------------------
-- 1. Затраты на производство за месяц (то, что попало в котёл 20.01),
--    по номенклатурной группе, слою и статье затрат. Это источник для
--    раскрытия «по статьям» в дашборде.
--
--    layer:  'Материалы'       — Дт 20.01 / Кт 10.01 (по номенклатуре
--                                материала, material);
--            'ОПР'             — Дт 20.01 / Кт 25 (общепроизводственные,
--                                статья — в cost_item);
--            'Прочие прямые'   — всё остальное в 20.01 (зарплата цеха,
--                                амортизация и т.п. напрямую).
-- ---------------------------------------------------------------------
CREATE VIEW IF NOT EXISTS bottling.cost_production AS
SELECT
    toStartOfMonth(period)  AS month,
    dr_ext1                 AS nomenclature_group,
    multiIf(cr_account = '10.01', 'Материалы',
            cr_account = '25',    'ОПР',
                                  'Прочие прямые') AS layer,
    dr_ext2                 AS cost_item,
    if(cr_account = '10.01', cr_ext1, '')          AS material,
    sum(amount)             AS amount
FROM bottling.cost_entries
WHERE dr_account = '20.01'
GROUP BY month, nomenclature_group, layer, cost_item, material;

-- ---------------------------------------------------------------------
-- 2. Себестоимость продаж за месяц — ТО, ЧТО ПРОВЕДЕНО В 90.02.1 —
--    разложенная на слои. Ключ: месяц x номенклатурная группа x слой.
--
--    Слои:
--      'Материалы'          — Дт 20.01/Кт 10.01 того же месяца и группы
--                             (списаны в продажи сразу);
--      'Прочие прямые'      — остальные прямые затраты 20.01 (кроме 25);
--      'ОПР со склада'      — Дт 90.02.1 / Кт 43 (общепроизводственные,
--                             прошедшие через готовую продукцию; БЕЗ
--                             разбивки по статьям — 1С её не хранит,
--                             придумывать пропорцию не стали);
--      'Вспомогательное'    — Дт 90.02.1 / Кт 23.01.
--    Прямые слои берутся из ПОСТУПЛЕНИЙ в 20.01, а не из списания:
--    списание 20.01→90.02.1 у 1С идёт одной суммой на группу без
--    статей. Совпадение проверяется во VIEW cost_of_sales_recon.
-- ---------------------------------------------------------------------
CREATE VIEW IF NOT EXISTS bottling.cost_of_sales AS
SELECT month, nomenclature_group, layer, cost_item, material, amount FROM
(
    SELECT month, nomenclature_group, layer, cost_item, material, amount
    FROM bottling.cost_production
    WHERE layer IN ('Материалы', 'Прочие прямые')

    UNION ALL

    SELECT
        toStartOfMonth(period) AS month,
        dr_ext1                AS nomenclature_group,
        multiIf(cr_account = '43',   'ОПР со склада',
                cr_account = '23.01','Вспомогательное',
                                     'Прочее со счетов') AS layer,
        ''                     AS cost_item,
        ''                     AS material,
        sum(amount)            AS amount
    FROM bottling.cost_entries
    WHERE dr_account LIKE '90.02%' AND cr_account != '20.01'
    GROUP BY month, nomenclature_group, layer
);

-- ---------------------------------------------------------------------
-- 3. Сверка с учётом: сколько проведено в Дт 90.02.1 (эталон) против
--    суммы слоёв. diff != 0 — повод разбираться (незавершёнка в 20.01 на
--    конец месяца, возвраты и т.п.), а не подгонять.
-- ---------------------------------------------------------------------
CREATE VIEW IF NOT EXISTS bottling.cost_of_sales_recon AS
SELECT
    b.month                AS month,
    b.nomenclature_group   AS nomenclature_group,
    b.booked               AS booked_9002,
    l.layers               AS layers_total,
    round(b.booked - l.layers, 2) AS diff
FROM
(
    SELECT toStartOfMonth(period) AS month, dr_ext1 AS nomenclature_group, sum(amount) AS booked
    FROM bottling.cost_entries
    WHERE dr_account LIKE '90.02%'
    GROUP BY month, nomenclature_group
) AS b
FULL JOIN
(
    SELECT month, nomenclature_group, sum(amount) AS layers
    FROM bottling.cost_of_sales
    GROUP BY month, nomenclature_group
) AS l USING (month, nomenclature_group);
