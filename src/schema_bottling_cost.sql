-- Себестоимость «Алабуга Боттлинг» по месяцам — БЕЗ партионного учёта,
-- «ставка месяца», совпадающая с текущим учётом 1С (счёт 90.02.1).
--
-- ПОЧЕМУ НЕ ПАРТИИ (разведка 2026-01..08, см. вики): 1С не считает
-- себестоимость при отгрузке — строки РеализацияТоваровУслуг проведены
-- почти на нули. Реальная себестоимость появляется при закрытии месяца
-- (Document_РегламентнаяОперация): котёл «20.01 Основное производство»
-- за месяц по номенклатурной группе списывается
--   * Дт 40 → Дт 43 — на склад готовой продукции (выпуск);
--   * Дт 90.02.1 / Кт 20.01 — сразу в себестоимость продаж;
-- а при продаже Дт 90.02.1 / Кт 43 списывает то, что лежало на складе.
-- Соотношение «на склад / сразу в продажи» ПЛАВАЕТ по месяцам (январь и
-- июнь — в основном сразу в продажи, остальные — в основном на склад;
-- в январе казалось, что на склад идёт только ОПР — это был частный
-- случай, не правило). Поэтому структуру списанной себестоимости по
-- поступлениям 20.01 того же месяца как факт брать нельзя.
--
-- ПРИНЯТАЯ МОДЕЛЬ («ставка месяца»): ИТОГ себестоимости продаж месяца по
-- номенклатурной группе = ровно то, что проведено в Дт 90.02.1 (как в
-- учёте). РАЗБИВКА итога на слои/статьи — пропорционально структуре
-- затрат 20.01 той же группы за тот же месяц (это распределение, не факт:
-- то, что списано со склада, могло быть выпущено в прошлые месяцы).
-- Если у группы в месяце нет поступлений в 20.01 (продали со склада, не
-- производя) — сумма идёт слоем «Без разбивки», а не размазывается по
-- чужой структуре.
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
CREATE OR REPLACE VIEW bottling.cost_production AS
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
-- 2. Себестоимость продаж за месяц (ИТОГ = Дт 90.02.1, как в учёте),
--    разложенная на слои и статьи ПРОПОРЦИОНАЛЬНО структуре затрат 20.01
--    той же группы за тот же месяц (cost_production). Слои: Материалы /
--    ОПР / Прочие прямые; либо 'Без разбивки' — если у группы в месяце
--    не было поступлений в 20.01. basis говорит, откуда разбивка.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW bottling.cost_of_sales AS
WITH
    booked AS
    (
        SELECT toStartOfMonth(period) AS month, dr_ext1 AS nomenclature_group, sum(amount) AS cogs
        FROM bottling.cost_entries
        WHERE dr_account LIKE '90.02%'
        GROUP BY month, nomenclature_group
    ),
    prod_tot AS
    (
        SELECT month, nomenclature_group, sum(amount) AS total
        FROM bottling.cost_production
        GROUP BY month, nomenclature_group
        HAVING total > 0
    )
SELECT
    b.month AS month, b.nomenclature_group AS nomenclature_group,
    p.layer AS layer, p.cost_item AS cost_item, p.material AS material,
    b.cogs * p.amount / t.total AS amount,
    'по структуре выпуска месяца' AS basis
FROM booked AS b
INNER JOIN bottling.cost_production AS p ON p.month = b.month AND p.nomenclature_group = b.nomenclature_group
INNER JOIN prod_tot AS t ON t.month = b.month AND t.nomenclature_group = b.nomenclature_group

UNION ALL

SELECT
    b.month, b.nomenclature_group,
    'Без разбивки' AS layer, '' AS cost_item, '' AS material,
    b.cogs AS amount,
    'нет выпуска группы в месяце' AS basis
FROM booked AS b
WHERE (b.month, b.nomenclature_group) NOT IN (SELECT month, nomenclature_group FROM prod_tot);

-- ---------------------------------------------------------------------
-- 3. Сверка: проведено в Дт 90.02.1 (эталон) против суммы слоёв
--    (по построению diff ≈ 0) + доля «Без разбивки» — то, что не удалось
--    разложить по структуре.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW bottling.cost_of_sales_recon AS
SELECT
    b.month AS month,
    b.nomenclature_group AS nomenclature_group,
    b.booked AS booked_9002,
    l.layers AS layers_total,
    round(b.booked - l.layers, 2) AS diff,
    l.no_split AS no_split_amount,
    if(b.booked != 0, l.no_split / b.booked, 0) AS no_split_share
FROM
(
    SELECT toStartOfMonth(period) AS month, dr_ext1 AS nomenclature_group, sum(amount) AS booked
    FROM bottling.cost_entries
    WHERE dr_account LIKE '90.02%'
    GROUP BY month, nomenclature_group
) AS b
LEFT JOIN
(
    SELECT month, nomenclature_group, sum(amount) AS layers, sumIf(amount, layer = 'Без разбивки') AS no_split
    FROM bottling.cost_of_sales
    GROUP BY month, nomenclature_group
) AS l ON l.month = b.month AND l.nomenclature_group = b.nomenclature_group;

-- ---------------------------------------------------------------------
-- 4. Контроль полноты загрузки: по каждому месяцу котёл 20.01 должен
--    закрываться (Дт = Кт). diff != 0 — месяц не закрыт в 1С (текущий)
--    или проводки загружены не полностью.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW bottling.cost_account_20_check AS
SELECT
    toStartOfMonth(period) AS month,
    sumIf(amount, dr_account = '20.01') AS debit_20,
    sumIf(amount, cr_account = '20.01') AS credit_20,
    round(debit_20 - credit_20, 2) AS diff
FROM bottling.cost_entries
GROUP BY month;
