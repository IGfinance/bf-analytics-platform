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
-- Папки номенклатуры: категория материала для «Подробной себестоимости»
-- (этикетки / QR-коды / преформы / колпачки… — папки справочника
-- Catalog_Номенклатура на втором уровне, глубже сворачиваются). Загрузчик —
-- src/ingest_bottling_material_folders.py; правило категории и возможность
-- задать свою группировку — там же (CATEGORY_OVERRIDES).
CREATE TABLE IF NOT EXISTS bottling.material_folder
(
    nomenclature_key   String,
    nomenclature       String,
    folder_path        String,   -- полный путь по иерархии, напр. 'Сырье и материалы / QR-коды / qr-код упаковка'
    material_category  String,   -- категория для раскрытия, напр. 'QR-коды'
    loaded_at          DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
ORDER BY nomenclature_key;

CREATE OR REPLACE VIEW bottling.cost_production AS
SELECT
    e.month AS month,
    e.nomenclature_group AS nomenclature_group,
    e.layer AS layer,
    e.cost_item AS cost_item,
    e.material AS material,
    if(e.layer = 'Материалы',
       if(c.category != '', c.category, 'Без категории (нет в справочнике)'),
       '') AS material_category,
    sum(e.amount) AS amount
FROM
(
    SELECT
        toStartOfMonth(period) AS month,
        dr_ext1 AS nomenclature_group,
        multiIf(cr_account = '10.01', 'Материалы',
                cr_account = '25',    'ОПР',
                                      'Прочие прямые') AS layer,
        dr_ext2 AS cost_item,
        if(cr_account = '10.01', cr_ext1, '') AS material,
        amount
    FROM bottling.cost_entries
    WHERE dr_account = '20.01'
) AS e
LEFT JOIN
(
    SELECT trimBoth(nomenclature) AS nomenclature, any(material_category) AS category
    FROM bottling.material_folder FINAL
    GROUP BY nomenclature
) AS c ON c.nomenclature = trimBoth(e.material)
GROUP BY month, nomenclature_group, layer, cost_item, material, material_category;

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
    p.layer AS layer, p.cost_item AS cost_item, p.material AS material, p.material_category AS material_category,
    b.cogs * p.amount / t.total AS amount,
    'по структуре выпуска месяца' AS basis
FROM booked AS b
INNER JOIN bottling.cost_production AS p ON p.month = b.month AND p.nomenclature_group = b.nomenclature_group
INNER JOIN prod_tot AS t ON t.month = b.month AND t.nomenclature_group = b.nomenclature_group

UNION ALL

SELECT
    b.month, b.nomenclature_group,
    'Без разбивки' AS layer, '' AS cost_item, '' AS material, '' AS material_category,
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

-- =====================================================================
-- СЕБЕСТОИМОСТЬ ПО ЗАКАЗУ (реализации клиенту) — ставкой месяца.
--
-- Строка реализации получает себестоимость = количество × ставка
-- (₽/шт) номенклатурной группы за месяц отгрузки, где
--     ставка = Дт 90.02.1 группы за месяц / проданное за месяц количество
-- группы. Сумма себестоимостей заказов группы за месяц = проведённому в
-- 90.02.1 (как в учёте). Это РАСПРЕДЕЛЕНИЕ по количеству, не фактическая
-- себестоимость конкретной бутылки: внутри группы разные SKU получают
-- одну ставку, а в 1С себестоимость «по заказу» не хранится (строки
-- реализации проведены почти на нули).
--
-- Честные пробелы (не выдумываем, считаем отдельно):
--   * себестоимость группы есть, продаж в месяце нет — она остаётся
--     «не распределённой» (cost_rate_month.status);
--   * у номенклатуры нет группы или в месяце нет себестоимости группы —
--     строка получает cost = 0 и cost_status объясняет почему;
--   * месяц не закрыт в 1С (котёл 20.01 не сходится) — ставка
--     предварительная, month_closed = 0.
-- =====================================================================

-- Справочник «номенклатура → номенклатурная группа» (Catalog_Номенклатура,
-- только позиции с заполненной группой; остальные в 1С без группы).
CREATE TABLE IF NOT EXISTS bottling.nomenclature_group
(
    nomenclature_key    String,
    nomenclature        String,
    nomenclature_group  String,
    loaded_at           DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
ORDER BY nomenclature_key;

-- Строки реализации (проведённые) с номенклатурной группой — ТОЛЬКО
-- тех месяцев, которые ЗАКРЫТЫ в 1С (котёл 20.01 сходится, см.
-- cost_account_20_check): для более ранних месяцев проводок в cost_entries
-- нет, а в открытом месяце (себестоимость ещё не списана) выручка без
-- себестоимости давала бы «маржу» ~100%. Месяц появляется сам, когда
-- проводки закрытого месяца догружены в cost_entries.
CREATE OR REPLACE VIEW bottling.cost_sales_lines AS
SELECT
    o.ref_key AS ref_key, o.number AS number, o.date AS date,
    toStartOfMonth(o.date) AS month,
    o.counterparty AS counterparty,
    i.line_number AS line_number,
    i.nomenclature_key AS nomenclature_key,
    i.nomenclature AS nomenclature,
    g.nomenclature_group AS nomenclature_group,
    i.quantity AS quantity,
    if(o.amount_includes_vat = 1, i.raw_amount - i.vat_amount, i.raw_amount) AS amount  -- выручка БЕЗ НДС (см. realization_revenue)
FROM (SELECT * FROM bottling.realization_orders FINAL WHERE posted = 1 AND deletion_mark = 0
      AND toStartOfMonth(date) IN (SELECT month FROM bottling.cost_account_20_check WHERE abs(diff) < 1 AND credit_20 > 0)) AS o
INNER JOIN (SELECT ref_key, line_number, nomenclature_key, nomenclature, quantity, vat_amount, amount AS raw_amount
            FROM bottling.realization_items FINAL) AS i ON i.ref_key = o.ref_key
LEFT JOIN (SELECT * FROM bottling.nomenclature_group FINAL) AS g ON g.nomenclature_key = i.nomenclature_key;

-- Ставка месяца по группе.
CREATE OR REPLACE VIEW bottling.cost_rate_month AS
WITH
    keys AS
    (
        SELECT month, nomenclature_group FROM
        (
            SELECT toStartOfMonth(period) AS month, dr_ext1 AS nomenclature_group
            FROM bottling.cost_entries WHERE dr_account LIKE '90.02%'
            UNION ALL
            SELECT month, nomenclature_group FROM bottling.cost_sales_lines WHERE nomenclature_group != ''
        )
        GROUP BY month, nomenclature_group
    ),
    booked AS
    (
        SELECT toStartOfMonth(period) AS month, dr_ext1 AS nomenclature_group, sum(amount) AS cogs
        FROM bottling.cost_entries WHERE dr_account LIKE '90.02%'
        GROUP BY month, nomenclature_group
    ),
    sold AS
    (
        SELECT month, nomenclature_group, sum(quantity) AS qty_sold, sum(amount) AS revenue
        FROM bottling.cost_sales_lines WHERE nomenclature_group != ''
        GROUP BY month, nomenclature_group
    )
SELECT
    k.month AS month,
    k.nomenclature_group AS nomenclature_group,
    coalesce(b.cogs, 0) AS cogs,
    coalesce(s.qty_sold, 0) AS qty_sold,
    coalesce(s.revenue, 0) AS revenue,
    if(coalesce(s.qty_sold, 0) > 0, coalesce(b.cogs, 0) / s.qty_sold, 0) AS rate_per_unit,
    multiIf(coalesce(s.qty_sold, 0) = 0 AND coalesce(b.cogs, 0) != 0, 'себестоимость без продаж (не распределена)',
            coalesce(b.cogs, 0) = 0 AND coalesce(s.qty_sold, 0) > 0,  'продажи без себестоимости',
                                                                       'ok') AS status,
    if(abs(c.diff) < 1 AND c.credit_20 > 0, 1, 0) AS month_closed  -- нет строки в cost_account_20_check → credit_20 = 0 → не закрыт
FROM keys AS k
LEFT JOIN booked AS b ON b.month = k.month AND b.nomenclature_group = k.nomenclature_group
LEFT JOIN sold   AS s ON s.month = k.month AND s.nomenclature_group = k.nomenclature_group
LEFT JOIN bottling.cost_account_20_check AS c ON c.month = k.month;

-- Пул месяца: себестоимость групп, у которых в месяце нет продаж
-- (напр. «Готовая продукция» в июне 2026 — 17,6 млн проведены под общей
-- группой, а продажи идут по конкретным; «Маркированная вода», «вода
-- артезианская»). Привязать её к продажам по группе нельзя. Чтобы итог
-- месяца совпал с учётом, пул РАСКЛАДЫВАЕТСЯ на строки реализации месяца
-- пропорционально выручке — отдельной колонкой cost_pool, не смешивается
-- со ставкой группы (cost). Это грубая оценка; если нужна только
-- «чистая» себестоимость по группе — смотрите cost, а не cost_total.
CREATE OR REPLACE VIEW bottling.cost_pool_month AS
SELECT r.month AS month, r.pool_cost AS pool_cost, m.month_revenue AS month_revenue
FROM (SELECT month, sumIf(cogs, qty_sold = 0) AS pool_cost FROM bottling.cost_rate_month GROUP BY month) AS r
LEFT JOIN (SELECT month, sum(amount) AS month_revenue FROM bottling.cost_sales_lines GROUP BY month) AS m ON m.month = r.month;

-- Себестоимость и маржа по строке реализации (заказ клиенту).
--   cost       — по ставке группы (количество × ₽/шт группы);
--   cost_pool  — доля пула месяца (по выручке), см. cost_pool_month;
--   cost_total = cost + cost_pool. Сумма cost_total за закрытый месяц =
--                Дт 90.02.1 за месяц (кроме строк без группы/ставки).
CREATE OR REPLACE VIEW bottling.cost_order_lines AS
SELECT
    l.ref_key AS ref_key, l.number AS number, l.date AS date, l.month AS month,
    l.counterparty AS counterparty, l.line_number AS line_number,
    l.nomenclature AS nomenclature, l.nomenclature_group AS nomenclature_group,
    l.quantity AS quantity, l.amount AS revenue,
    l.quantity * coalesce(r.rate_per_unit, 0) AS cost,
    if(p.month_revenue != 0, p.pool_cost * l.amount / p.month_revenue, 0) AS cost_pool,
    cost + cost_pool AS cost_total,
    l.amount - cost AS margin,
    l.amount - cost_total AS margin_total,
    multiIf(l.nomenclature_group = '', 'нет номенклатурной группы',
            r.status = 'ok', 'ok',
            r.status = '', 'нет данных',  -- LEFT JOIN без совпадения даёт пустую строку, не NULL
            r.status) AS cost_status,
    coalesce(r.month_closed, 0) AS month_closed
FROM bottling.cost_sales_lines AS l
LEFT JOIN bottling.cost_rate_month AS r ON r.month = l.month AND r.nomenclature_group = l.nomenclature_group
LEFT JOIN bottling.cost_pool_month AS p ON p.month = l.month;

-- Та же себестоимость строки, разложенная на слои (Материалы / ОПР /
-- Прочие прямые / Без разбивки — структура по cost_of_sales месяца) +
-- слой 'Не привязана к группе (пул месяца)'.
CREATE OR REPLACE VIEW bottling.cost_order_layers AS
SELECT
    l.ref_key AS ref_key, l.number AS number, l.date AS date, l.month AS month,
    l.counterparty AS counterparty, l.nomenclature AS nomenclature,
    l.nomenclature_group AS nomenclature_group,
    c.layer AS layer,
    l.quantity * c.layer_amount / r.qty_sold AS cost
FROM bottling.cost_sales_lines AS l
INNER JOIN bottling.cost_rate_month AS r
    ON r.month = l.month AND r.nomenclature_group = l.nomenclature_group AND r.qty_sold > 0
INNER JOIN
(
    SELECT month, nomenclature_group, layer, sum(amount) AS layer_amount
    FROM bottling.cost_of_sales
    GROUP BY month, nomenclature_group, layer
) AS c ON c.month = l.month AND c.nomenclature_group = l.nomenclature_group

UNION ALL

SELECT
    ref_key, number, date, month, counterparty, nomenclature, nomenclature_group,
    'Не привязана к группе (пул месяца)' AS layer,
    cost_pool AS cost
FROM bottling.cost_order_lines
WHERE cost_pool != 0;

-- Возвраты от покупателей (bottling.returns_net, сумма БЕЗ НДС) по тем же
-- закрытым месяцам и с той же номенклатурной группой, что и строки
-- реализации. Вычитаются из выручки: «Чистая выручка» = Выручка − Возвраты.
CREATE OR REPLACE VIEW bottling.cost_returns_lines AS
SELECT
    r.ref_key AS ref_key, r.number AS number, r.date AS date, r.month AS month,
    r.counterparty AS counterparty, r.nomenclature AS nomenclature,
    g.nomenclature_group AS nomenclature_group,
    r.quantity AS quantity, r.amount AS amount
FROM bottling.returns_net AS r
LEFT JOIN (SELECT * FROM bottling.nomenclature_group FINAL) AS g ON g.nomenclature_key = r.nomenclature_key
WHERE r.month IN (SELECT month FROM bottling.cost_account_20_check WHERE abs(diff) < 1 AND credit_20 > 0);

-- Длинная сводка для дашборда: месяц x компания x группа x номенклатура x
-- показатель. Один источник под общие фильтры Период/Компания/Группа
-- (у Metabase field filter привязан к одному полю одной таблицы).
-- sort — порядок строк показателей в кросс-табе. ОДИН проход по
-- cost_order_lines (раньше — 4 UNION ALL-ветки, каждая пересчитывала
-- вложенные VIEW, ≈18 с на месяц и 504 в Metabase): слои строки =
-- cost × доля слоя в cost_of_sales группы за месяц.
CREATE OR REPLACE VIEW bottling.cost_summary_long AS
WITH shares AS
(
    SELECT month, nomenclature_group, groupArray((layer, layer_amount / total)) AS ls
    FROM
    (
        SELECT month, nomenclature_group, layer, layer_amount,
               sum(layer_amount) OVER (PARTITION BY month, nomenclature_group) AS total
        FROM
        (
            SELECT month, nomenclature_group, layer, sum(amount) AS layer_amount
            FROM bottling.cost_of_sales GROUP BY month, nomenclature_group, layer
        )
    )
    WHERE total != 0
    GROUP BY month, nomenclature_group
)
SELECT
    l.month AS month, l.counterparty AS counterparty,
    l.nomenclature_group AS nomenclature_group, l.nomenclature AS nomenclature,
    m.1 AS metric, m.2 AS sort, m.3 AS amount
FROM bottling.cost_order_lines AS l
LEFT JOIN shares AS s ON s.month = l.month AND s.nomenclature_group = l.nomenclature_group
ARRAY JOIN arrayConcat(
    [('Выручка', toUInt8(1), toFloat64(l.revenue)),
     ('Себестоимость (итого)', toUInt8(7), toFloat64(l.cost_total)),
     ('Маржа', toUInt8(8), toFloat64(l.margin_total))],
    if(l.cost_pool != 0, [('Не привязана к группе (пул месяца)', toUInt8(6), toFloat64(l.cost_pool))], []),
    arrayMap(x -> (x.1,
                   toUInt8(multiIf(x.1 = 'Материалы', 2, x.1 = 'ОПР', 3, x.1 = 'Прочие прямые', 4, x.1 = 'Без разбивки', 5, 6)),
                   toFloat64(l.cost * x.2)), s.ls)
) AS m

UNION ALL

-- возвраты: метрика 'Возвраты' (+) и уменьшение 'Маржи' (−)
SELECT
    r.month AS month, r.counterparty AS counterparty,
    r.nomenclature_group AS nomenclature_group, r.nomenclature AS nomenclature,
    m.1 AS metric, m.2 AS sort, m.3 AS amount
FROM bottling.cost_returns_lines AS r
ARRAY JOIN [('Возвраты', toUInt8(9), toFloat64(r.amount)),
            ('Маржа', toUInt8(8), toFloat64(-r.amount))] AS m;
