-- База `bottling` — новый клиент «Алабуга Боттлинг», источник данных 1С
-- OData (не WB/Ozon, у клиента нет маркетплейсов — прямые продажи
-- контрагентам). Отдельная БД, а не таблицы внутри cloudsix/realt —
-- тот же принцип изоляции клиентов, что уже есть для cloudsix/realt
-- (см. docs/vision.md, раздел «Узкие ClickHouse-пользователи для
-- Metabase»). Подключение к 1С — src/odata_bottling_core.py,
-- см. docs/odata-alabuga-bottling-entities.md (каталог всех объектов
-- базы) и knowledge/integrations/«1С OData — подключение работает...»
-- в вики.
--
-- ДВЕ ТАБЛИЦЫ — заказы и строки заказов, соединяются по ref_key.
-- Ровно та структура, которую владелец попросил 2026-09-30: "Заголовок"
-- документа "Реализация товаров и услуг" → realization_orders,
-- табличная часть "Товары" → realization_items. Формула выручки живёт
-- ПОВЕРХ этих двух таблиц (VIEW realization_revenue ниже), а не в них —
-- сами таблицы хранят как есть, без фильтра по Posted/DeletionMark,
-- чтобы повторная загрузка видела смену статуса документа (черновик
-- стал проведён, или наоборот).
--
-- ПОЧЕМУ ref_key, а не Number, ключ соединения: Number НЕ уникален у
-- этой базы — нумерация сбрасывается, один номер встречается у разных
-- документов (проверено 2026-09-29 на выгрузке: 8531 из 17044 номеров
-- дублируются, напр. "ПЛБП-002330" — у 8 разных продаж). ref_key —
-- GUID документа в 1С, гарантированно уникален.
--
-- ФИЛЬТР ПРОВЕДЕНИЯ — важно при любом использовании этих таблиц.
-- Непроведённые документы — это не факт хозяйственной жизни (черновик,
-- отменённый заказ и т.п.). На выгрузке 2026-09-29 из 150511 документов
-- проведено только 46606 (31%) — и это НЕ мусор: у 2025 года отдельно
-- нашлась аномалия — 90621 документов, из них 81636 непроведённых БЕЗ
-- контрагента и в основном с нулевой суммой (похоже на сбойную
-- интеграцию/тестовую массовую генерацию) — см. вики-сессию 2026-09-29,
-- "выручка по проведённым документам растёт плавно год к году, провала
-- в 2025-м нет" — так что фильтр posted=1 отсекает именно мусор, не
-- реальные продажи. Использовать realization_revenue (уже фильтрует),
-- либо добавлять `WHERE posted = 1 AND deletion_mark = 0` руками.

CREATE DATABASE IF NOT EXISTS bottling;

CREATE TABLE IF NOT EXISTS bottling.realization_orders
(
    ref_key              String,    -- Ref_Key документа — уникальный ключ, соединяется с realization_items.ref_key
    number               String,    -- Number — НЕ уникален, см. заголовок файла
    date                 DateTime,  -- Date шапки документа
    posted               UInt8,     -- Posted — проведён ли документ
    deletion_mark        UInt8,     -- DeletionMark — помечен на удаление

    counterparty_key     String,    -- Контрагент_Key
    counterparty         String,    -- Контрагент, расшифровка из Catalog_Контрагенты
    contract_key         String,    -- ДоговорКонтрагента_Key
    contract             String,    -- ДоговорКонтрагента, расшифровка
    price_type_key       String,    -- ТипЦен_Key
    price_type           String,    -- ТипЦен, расшифровка
    currency_key         String,    -- ВалютаДокумента_Key
    currency             String,    -- ВалютаДокумента, расшифровка ('руб.' у всех строк на 2026-09-29)
    exchange_rate        Float64,   -- КурсВзаиморасчетов
    amount_includes_vat  UInt8,     -- СуммаВключаетНДС
    document_amount      Float64,   -- СуммаДокумента — итог шапки; НЕ обязан совпадать с суммой строк realization_items (есть ещё табличные части Услуги/ЗачетАвансов и т.п., сюда не загруженные)
    responsible_key      String,    -- Ответственный_Key
    responsible          String,    -- Ответственный, расшифровка

    loaded_at             DateTime DEFAULT now()  -- для ReplacingMergeTree — дата последней загрузки строки
)
ENGINE = ReplacingMergeTree(loaded_at)
PARTITION BY toYYYYMM(date)
ORDER BY (ref_key);

ALTER TABLE bottling.realization_orders COMMENT COLUMN ref_key 'GUID документа в 1С (Ref_Key). Уникальный ключ — соединяется с realization_items.ref_key. FINAL обязателен при чтении (ReplacingMergeTree).';
ALTER TABLE bottling.realization_orders COMMENT COLUMN number 'Номер документа. НЕ уникален у этой базы — нумерация сбрасывается, не использовать как ключ соединения.';
ALTER TABLE bottling.realization_orders COMMENT COLUMN posted 'Проведён ли документ (1С Posted). Непроведённые — черновики/отменённые, не факт хозяйственной жизни. Фильтровать WHERE posted=1.';
ALTER TABLE bottling.realization_orders COMMENT COLUMN document_amount 'Итоговая сумма документа из шапки. Может не совпадать с суммой по realization_items — в шапке есть и другие табличные части (Услуги и т.п.), сюда не загруженные.';

CREATE TABLE IF NOT EXISTS bottling.realization_items
(
    ref_key           String,   -- FK -> realization_orders.ref_key
    line_number       UInt32,   -- LineNumber — номер строки внутри документа

    nomenclature_key  String,   -- Номенклатура_Key
    nomenclature      String,   -- Номенклатура, расшифровка из Catalog_Номенклатура — что именно продано
    qty_places        Float64,  -- КоличествоМест (упаковок/паллет — не единица товара)
    unit_key          String,   -- ЕдиницаИзмерения_Key
    unit              String,   -- ЕдиницаИзмерения, расшифровка
    coefficient       Float64,  -- Коэффициент пересчёта единицы измерения
    quantity          Float64,  -- Количество проданных единиц
    price             Float64,  -- Цена за единицу
    amount            Float64,  -- Сумма строки — БЕЗ НДС, это и есть выручка по строке
    vat_rate          String,   -- СтавкаНДС (напр. 'НДС20')
    vat_amount        Float64,  -- СуммаНДС строки

    loaded_at          DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
ORDER BY (ref_key, line_number);

ALTER TABLE bottling.realization_items COMMENT COLUMN ref_key 'GUID документа-шапки (Ref_Key). Соединяется с realization_orders.ref_key. У одного ref_key может быть несколько строк (несколько проданных товаров в одной продаже).';
ALTER TABLE bottling.realization_items COMMENT COLUMN amount 'Сумма строки БЕЗ НДС — это и есть выручка по этому товару в этой продаже. С учётом НДС — amount + vat_amount.';

-- Выручка = realization_orders JOIN realization_items ПО ref_key,
-- отфильтрованные posted=1 и deletion_mark=0. FINAL обязателен у обеих
-- таблиц (ReplacingMergeTree, без FINAL повторная загрузка считалась бы
-- дважды).
CREATE VIEW IF NOT EXISTS bottling.realization_revenue AS
SELECT
    o.ref_key                       AS ref_key,
    o.number                        AS number,
    o.date                          AS date,
    toStartOfMonth(o.date)          AS month,
    o.counterparty                  AS counterparty,
    o.contract                      AS contract,
    o.responsible                   AS responsible,
    i.line_number                   AS line_number,
    i.nomenclature                  AS nomenclature,
    i.quantity                      AS quantity,
    i.unit                          AS unit,
    i.price                         AS price,
    i.amount                        AS amount,
    i.vat_amount                    AS vat_amount,
    (i.amount + i.vat_amount)       AS amount_with_vat
FROM (SELECT * FROM bottling.realization_orders FINAL WHERE posted = 1 AND deletion_mark = 0) AS o
INNER JOIN (SELECT * FROM bottling.realization_items FINAL) AS i ON i.ref_key = o.ref_key;

ALTER TABLE bottling.realization_revenue COMMENT COLUMN amount 'Выручка по строке, БЕЗ НДС. Источник истины для метрики "выручка" — сумма этой колонки, сгруппированная по month/counterparty/nomenclature.';
