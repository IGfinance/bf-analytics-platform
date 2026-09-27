-- VIEW-слой с бизнес-формулами метрик WB — КАНОНИЧЕСКИЙ источник истины
-- для всех разрезов (по кабинету/месяцу, по SKU). Раньше wb_metrics_by_cabinet_month
-- (schema_wb_metrics_views.sql) пересчитывал ту же формулу из wb_reports
-- независимо — с 2026-09-14 он стал тонкой агрегацией (GROUP BY cabinet,
-- month, sum(...)) поверх ЭТОГО VIEW, а не отдельным вычислением. Меняйте
-- формулы ТОЛЬКО здесь.
--
-- Раньше был архивный аналог ("Модель - WB юнит-экономика по SKU и месяцу",
-- id 57, см. architecture-map.md) — архивирован без объяснения, и при
-- проверке 2026-09-14 обнаружено, что он был построен на СТАРОЙ, уже
-- исправленной формуле: sum_loyalty_cost/sum_loyalty_points считались
-- простым sum() без вычета двойного счёта возвратов (тот же баг, что
-- чинили в wb_metrics_by_cabinet_month 2026-09-13, см. её заголовок).
-- Этот VIEW — не реанимация старой модели, а пересборка с нуля на
-- актуальной формуле (тот же base CTE, что в wb_metrics_by_cabinet_month
-- на 2026-09-14, без transport_warehouse_compensation).
--
-- ВАЖНО про группировку: артикул — это доп. измерение, а не альтернатива
-- кабинету/месяцу. Любая карточка поверх этого VIEW, показывающая сумму
-- по метрике, ДОЛЖНА фильтровать или группировать по sku (и обычно по
-- cabinet) — иначе строки разных артикулов с одинаковым (кабинет, месяц)
-- молча просуммируются, это тот же класс бага, что был с "Кабинет" в
-- wb_metrics_by_month.sql (см. её "Обновление 2026-09-05").
--
-- sku — supplier_article ("Артикул поставщика" из wb_reports), пустые
-- значения помечены как 'без артикула', а не NULL/пусто, чтобы не
-- потерять такие строки при GROUP BY/фильтрации.
--
-- СЕБЕСТОИМОСТЬ (с 2026-09-23). Считается из wb_cogs_weekly (ручная
-- выгрузка .xlsx, см. schema_wb_cogs.sql) отдельным CTE cogs_agg и
-- присоединяется к base ПОСЛЕ агрегации, по ключу (cabinet, month, sku) —
-- то есть один-к-одному. Это сделано намеренно: join к сырым строкам
-- wb_reports внутри base при любом задвоении справочника размножил бы
-- строки и тихо испортил ВСЕ метрики, а не только себестоимость.
--
-- Сопоставление: артикул в нижнем регистре + неделя продажи
-- (toMonday(sale_date), понедельник-воскресенье, как в самом файле
-- себестоимости). Берётся неделя ТОЙ операции, которая стоит в строке
-- отчёта: продажа — со знаком плюс, возврат — со знаком минус, по той
-- себестоимости, что действовала в неделю этой операции. Возврат НЕ
-- отматывается к неделе исходной продажи — в строках возврата WB нет
-- ссылки на дату первоначальной продажи, поэтому такой вариант
-- технически недостижим, а не отвергнут.
--
-- Артикулы, которых нет в файле себестоимости, дают cogs = 0 (решение
-- пользователя 2026-09-23: занижать, но не выдумывать цену). Чтобы
-- занижение было видно, а не пряталось, рядом живут две СЧЁТНЫЕ колонки —
-- cogs_qty_covered и cogs_qty_uncovered: сколько проданных единиц попало
-- под известную себестоимость, а сколько осталось без неё. Проверка на
-- данных 2026-09-23: покрыто 85% проданных единиц по проекту (CloudSix
-- 97%, Hauser 99%, NoxLab 99%, INOVO 97%, Torado 86%, Feel 72%, Lampa 66%,
-- ARB 42%) — низкое покрытие лечится дозаливкой файла, а не правкой формул.
--
-- payable_total себестоимость НЕ включает и включать не должна: это
-- "К перечислению" (что платит WB), на нём стоят сверки
-- (compare_wb_sources.py, reconciliation_rules_wb.yaml). Себестоимость
-- участвует только в gross_profit = payable_total + cogs.
--
-- ПРАВКА 2026-09-27 — sales_corrections (найдено при сверке дашборда с
-- адаптерами, файл data-files/Сверка_WB_дашборд_vs_адаптеры_25_09_26.xlsx).
-- Белый список cs_k_types покрывает НЕ ВСЕ payment_reason, у которых есть
-- деньги в payable_to_seller: мимо него шли "Коррекция продаж",
-- "Корректировка эквайринга" и "Услуга платная доставка" — то есть
-- payable_for_goods молча занижался. Теперь дополнение к cs_k_types
-- (ВСЁ, что не попало в белый список) считается отдельной метрикой
-- sales_corrections и входит в payable_for_goods.
--
-- Знак берётся по document_type (Продажа плюсом, Возврат минусом), как у
-- основных строк. Это НЕ то же, что делает внешний адаптер: он прибавляет
-- такие строки со знаком "как лежит", не разворачивая Возвраты. Источник
-- истины здесь — СВОДНЫЙ отчёт WB (wb_report_summary, колонка
-- "К перечислению за товар"), и он считает именно по document_type, без
-- фильтра по payment_reason (см. reconciliation_rules_wb.yaml). Проверено
-- на всех 66 отчётах CloudSix: новая формула payable_for_goods сходится со
-- сводным отчётом с diff = 0.00 на каждом отчёте, тогда как прежняя
-- расходилась на 8 отчётах (до 269.78 ₽), а вариант адаптера — на 6
-- (до 540.62 ₽, то есть хуже прежнего).
--
-- Что именно попало в дополнение и насколько это доказано сводным отчётом
-- (сводный отчёт загружен только по CloudSix, отсюда разное покрытие):
--   "Коррекция продаж"         13 943.96 ₽, 6 кабинетов — 7 отчётов покрыты
--                              сводным, сходятся → доказано;
--   "Корректировка эквайринга"      75.39 ₽, 5 кабинетов — 2 отчёта покрыты,
--                              сходятся → доказано;
--   "Услуга платная доставка"       30.08 ₽, только INOVO 2026-06 — сводного
--                              отчёта по INOVO нет, НЕ проверено напрямую,
--                              включено по общему правилу (в формуле сводного
--                              отчёта фильтра по payment_reason нет вообще).
-- Дополнение намеренно описано как "всё, что не в cs_k_types", а не списком
-- этих трёх: новый payment_reason с деньгами, который WB добавит завтра,
-- попадёт в метрику сам. Прежнее поведение (белый список) молча терял бы его —
-- это худший режим отказа, чем лишняя строка в "Корректировках продаж".
--
-- Разбивка cs_k_types / дополнение сделана вместо простого снятия фильтра,
-- чтобы не поехала wb_commission: она считается как
-- payable_for_goods - retail_price_with_discount, и если в payable попадут
-- строки корректировок, которых нет в retail, комиссия молча впитает их.
-- Поэтому ядро (ah_sale/ah_ret) осталось как было, а корректировки живут
-- отдельной колонкой — ровно как returns_corrections у Ozon
-- (schema_ozon_metrics_views.sql). Сумма ядра и дополнения тождественно
-- равна "по всем строкам" (проверено: 334 073 530.40 ₽ обоими способами),
-- поэтому coalesce(..., '') в NOT IN обязателен — без него строки с
-- payment_reason IS NULL выпали бы из обеих частей.

-- ГОЧТЯ при накате на прод: `CREATE OR REPLACE VIEW` сбрасывает ВСЕ
-- `COMMENT COLUMN` на этой VIEW — после правки тела прогоняйте все
-- ALTER-команды из конца файла заново (8 из 24 колонок; остальные
-- намеренно без комментариев, их пояснения — в schema_wb_metrics_views.sql).
-- Подробнее — в заголовке schema_wb_metrics_views.sql.

CREATE VIEW IF NOT EXISTS wb_metrics_by_sku_month AS
WITH cs_k_types AS (
    SELECT arrayJoin([
        'продажа', 'сторно продаж', 'авансовая оплата за товар без движения',
        'возврат', 'корректный возврат', 'корректная продажа',
        'компенсация брака', 'компенсация потерянного товара',
        'сторно возвратов', 'компенсация ущерба',
        'добровольная компенсация при возврате',
        'компенсация подмененного товара', 'частичная компенсация брака'
    ]) AS v
),
base AS (
    SELECT
        cabinet,
        toDateTime(toStartOfMonth(sale_date)) + INTERVAL 12 HOUR AS month,
        coalesce(nullIf(trim(supplier_article), ''), 'без артикула') AS sku,
        anyHeavy(product_name) AS product_name,

        coalesce(sumIf(qty, lowerUTF8(trim(payment_reason)) = 'продажа'), 0) AS n_sale,
        coalesce(sumIf(qty, lowerUTF8(trim(payment_reason)) = 'возврат'), 0) AS n_ret,

        coalesce(sumIf(wb_realized_amount,
            lowerUTF8(trim(payment_reason)) IN (SELECT v FROM cs_k_types) AND lowerUTF8(trim(document_type)) = 'продажа'), 0) AS p_sale,
        coalesce(sumIf(wb_realized_amount,
            lowerUTF8(trim(payment_reason)) IN (SELECT v FROM cs_k_types) AND lowerUTF8(trim(document_type)) = 'возврат'), 0) AS p_ret,
        coalesce(sumIf(retail_price_with_discount,
            lowerUTF8(trim(payment_reason)) IN (SELECT v FROM cs_k_types) AND lowerUTF8(trim(document_type)) = 'продажа'), 0) AS t_sale,
        coalesce(sumIf(retail_price_with_discount,
            lowerUTF8(trim(payment_reason)) IN (SELECT v FROM cs_k_types) AND lowerUTF8(trim(document_type)) = 'возврат'), 0) AS t_ret,
        coalesce(sumIf(payable_to_seller,
            lowerUTF8(trim(payment_reason)) IN (SELECT v FROM cs_k_types) AND lowerUTF8(trim(document_type)) = 'продажа'), 0) AS ah_sale,
        coalesce(sumIf(payable_to_seller,
            lowerUTF8(trim(payment_reason)) IN (SELECT v FROM cs_k_types) AND lowerUTF8(trim(document_type)) = 'возврат'), 0) AS ah_ret,

        -- дополнение к cs_k_types: всё, что не попало в белый список
        -- ("Коррекция продаж", "Корректировка эквайринга", "Услуга платная
        -- доставка" и любые новые типы, которые WB добавит). coalesce(...,'')
        -- нужен, чтобы NULL-payment_reason не выпал из обеих частей разбивки.
        coalesce(sumIf(payable_to_seller,
            coalesce(lowerUTF8(trim(payment_reason)), '') NOT IN (SELECT v FROM cs_k_types) AND lowerUTF8(trim(document_type)) = 'продажа'), 0) AS corr_sale,
        coalesce(sumIf(payable_to_seller,
            coalesce(lowerUTF8(trim(payment_reason)), '') NOT IN (SELECT v FROM cs_k_types) AND lowerUTF8(trim(document_type)) = 'возврат'), 0) AS corr_ret,

        coalesce(sumIf(delivery_service_cost,
            payment_reason IN ('Логистика', 'Коррекция логистики') AND logistics_fines_corrections_type LIKE '%К клиенту%'), 0) AS direct_logistics,
        coalesce(sumIf(delivery_service_cost,
            payment_reason IN ('Логистика', 'Коррекция логистики') AND (logistics_fines_corrections_type NOT LIKE '%К клиенту%' OR logistics_fines_corrections_type IS NULL)), 0) AS reverse_logistics,

        coalesce(sum(total_fines), 0) AS sum_fines,
        coalesce(sum(wb_commission_correction), 0) AS sum_correction,
        coalesce(sum(storage_cost), 0) AS sum_storage,
        coalesce(sum(acceptance_operations), 0) AS sum_acceptance,
        coalesce(sumIf(deductions,
            trim(REGEXP_REPLACE(REGEXP_REPLACE(logistics_fines_corrections_type, ',\\s*документ\\s*№\\s*\\d+', ''), '\\s+\\d+$', ''))
                NOT IN ('Оказание услуг «WB Продвижение»', 'Оказание услуг «ВБ.Продвижение»')
            OR logistics_fines_corrections_type IS NULL), 0) AS sum_deductions,
        coalesce(sumIf(deductions,
            trim(REGEXP_REPLACE(REGEXP_REPLACE(logistics_fines_corrections_type, ',\\s*документ\\s*№\\s*\\d+', ''), '\\s+\\d+$', ''))
                IN ('Оказание услуг «WB Продвижение»', 'Оказание услуг «ВБ.Продвижение»')), 0) AS sum_promo,

        coalesce(sumIf(loyalty_discount_compensation, document_type = 'Продажа'), 0)
          - coalesce(sumIf(loyalty_discount_compensation, document_type = 'Возврат'), 0) AS sum_loyalty_comp,
        coalesce(sum(loyalty_program_cost), 0)
          - 2 * coalesce(sumIf(loyalty_program_cost, document_type = 'Возврат'), 0) AS sum_loyalty_cost,
        coalesce(sum(loyalty_points_deducted), 0)
          - 2 * coalesce(sumIf(loyalty_points_deducted, document_type = 'Возврат'), 0) AS sum_loyalty_points
    FROM wb_reports
    WHERE sale_date IS NOT NULL
    GROUP BY cabinet, month, sku
),
cogs_agg AS (
    SELECT
        r.cabinet AS cabinet,
        toDateTime(toStartOfMonth(r.sale_date)) + INTERVAL 12 HOUR AS month,
        coalesce(nullIf(trim(r.supplier_article), ''), 'без артикула') AS sku,
        -- has_cost, а не проверка unit_cost на NULL: в ClickHouse LEFT JOIN
        -- по умолчанию подставляет 0, и настоящая нулевая цена была бы
        -- неотличима от отсутствия строки в справочнике.
        coalesce(sum(r.net_qty * w.unit_cost), 0)          AS cogs_amount,
        coalesce(sum(if(w.has_cost = 1, r.net_qty, 0)), 0) AS qty_covered,
        coalesce(sum(if(w.has_cost = 1, 0, r.net_qty)), 0) AS qty_uncovered
    FROM (
        SELECT
            cabinet,
            sale_date,
            supplier_article,
            lowerUTF8(trim(supplier_article)) AS sku_key,
            toMonday(sale_date) AS week_start,
            multiIf(lowerUTF8(trim(payment_reason)) = 'продажа', qty,
                    lowerUTF8(trim(payment_reason)) = 'возврат', -qty,
                    0) AS net_qty
        FROM wb_reports
        WHERE sale_date IS NOT NULL
          AND lowerUTF8(trim(payment_reason)) IN ('продажа', 'возврат')
    ) r
    LEFT JOIN (
        SELECT sku, week_start, unit_cost, toUInt8(1) AS has_cost
        FROM wb_cogs_weekly FINAL
    ) w ON r.sku_key = w.sku AND r.week_start = w.week_start
    GROUP BY cabinet, month, sku
)
SELECT
    cabinet                                               AS cabinet,
    month                                                  AS month,
    sku                                                    AS sku,
    product_name                                           AS product_name,
    (n_sale - n_ret)                                       AS sales_qty,
    (p_sale - p_ret)                                       AS sales_amount,
    ((t_sale - t_ret) - (p_sale - p_ret))                  AS spp_amount,
    ((ah_sale - ah_ret) - (t_sale - t_ret))                AS wb_commission,
    (corr_sale - corr_ret)                                 AS sales_corrections,
    ((ah_sale - ah_ret) + (corr_sale - corr_ret))          AS payable_for_goods,
    (-direct_logistics)                                    AS logistics_direct,
    (-reverse_logistics)                                   AS logistics_reverse,
    (-sum_fines)                                           AS fines,
    (-sum_correction)                                      AS commission_correction,
    (-sum_storage)                                         AS storage_cost,
    (-sum_acceptance)                                      AS acceptance_cost,
    (-sum_deductions)                                      AS deductions,
    (sum_loyalty_comp - sum_loyalty_cost - sum_loyalty_points) AS wibes_discount,
    (-sum_promo)                                           AS promotion_cost,
    (
      (ah_sale - ah_ret) + (corr_sale - corr_ret) + (-direct_logistics) + (-reverse_logistics)
      + (-sum_fines) + (-sum_correction) + (-sum_storage) + (-sum_acceptance) + (-sum_deductions)
      + (sum_loyalty_comp - sum_loyalty_cost - sum_loyalty_points) + (-sum_promo)
    )                                                       AS payable_total,
    (-coalesce(c.cogs_amount, 0))                           AS cogs,
    (
      (ah_sale - ah_ret) + (corr_sale - corr_ret) + (-direct_logistics) + (-reverse_logistics)
      + (-sum_fines) + (-sum_correction) + (-sum_storage) + (-sum_acceptance) + (-sum_deductions)
      + (sum_loyalty_comp - sum_loyalty_cost - sum_loyalty_points) + (-sum_promo)
      - coalesce(c.cogs_amount, 0)
    )                                                       AS gross_profit,
    toInt64(coalesce(c.qty_covered, 0))                     AS cogs_qty_covered,
    toInt64(coalesce(c.qty_uncovered, 0))                   AS cogs_qty_uncovered
FROM base
LEFT JOIN cogs_agg c
    ON base.cabinet = c.cabinet AND base.month = c.month AND base.sku = c.sku
ORDER BY cabinet, sku, month;

ALTER TABLE wb_metrics_by_sku_month COMMENT COLUMN sku 'Артикул продавца (supplier_article из wb_reports), пустые значения — ''без артикула''. Доп. измерение поверх той же формулы, что wb_metrics_by_cabinet_month.';
ALTER TABLE wb_metrics_by_sku_month COMMENT COLUMN product_name 'Название товара — anyHeavy(product_name) по артикулу (самое частое встреченное название, на случай расхождений в написании за разные периоды).';
ALTER TABLE wb_metrics_by_sku_month COMMENT COLUMN sales_corrections 'Корректировки продаж, ₽ — payable_to_seller по строкам, payment_reason которых НЕ входит в белый список cs_k_types ("Коррекция продаж", "Корректировка эквайринга", "Услуга платная доставка"). Знак по document_type: Продажа плюсом, Возврат минусом. Входит в payable_for_goods — до 2026-09-27 эти деньги терялись целиком. Внешний адаптер считает их иначе (прибавляет Возвраты, а не вычитает) и со сводным отчётом WB не сходится, наша формула сходится — см. заголовок файла.';
ALTER TABLE wb_metrics_by_sku_month COMMENT COLUMN payable_for_goods 'К перечислению за товар = (payable_to_seller продажа минус возврат по cs_k_types) + sales_corrections. Тождественно равно "payable_to_seller по ВСЕМ строкам, Продажа минус Возврат" — то есть ровно формуле сводного отчёта WB (reconciliation_rules_wb.yaml, правило "К перечислению за товар"), diff = 0.00 на всех 66 отчётах CloudSix.';
ALTER TABLE wb_metrics_by_sku_month COMMENT COLUMN cogs 'Себестоимость проданного товара, ₽, знак инвертирован (расход, как штрафы и логистика). Считается как (продажи минус возвраты) в штуках × себестоимость единицы за НЕДЕЛЮ операции из wb_cogs_weekly. Артикулы, которых нет в справочнике себестоимости, дают 0 — насколько цифра занижена, видно по cogs_qty_uncovered. В payable_total НЕ входит.';
ALTER TABLE wb_metrics_by_sku_month COMMENT COLUMN gross_profit 'Валовая прибыль = payable_total + cogs (cogs отрицательный). Занижена ровно настолько, насколько не покрыт справочник себестоимости — смотрите cogs_qty_uncovered рядом.';
ALTER TABLE wb_metrics_by_sku_month COMMENT COLUMN cogs_qty_covered 'Сколько проданных единиц (продажи минус возвраты) нашли себестоимость на свою неделю. Колонка счётная, суммируется по месяцам и артикулам свободно.';
ALTER TABLE wb_metrics_by_sku_month COMMENT COLUMN cogs_qty_uncovered 'Сколько проданных единиц (продажи минус возвраты) остались БЕЗ себестоимости и посчитаны по нулю. Ненулевое значение = cogs/gross_profit занижены, лечится дозаливкой файла себестоимости (ingest_wb_cogs.py), а не правкой формул. Процент покрытия считайте как covered/(covered+uncovered) в карточке — готовой колонки-доли здесь нет намеренно, такую долю нельзя суммировать по месяцам.';
