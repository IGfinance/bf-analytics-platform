-- СГЕНЕРИРОВАННЫЙ ФАЙЛ. Не правьте руками.
--
-- Генератор: scripts/gen_ozon_brand_views.py (там же — правила и обоснование).
-- Источник формул: schema_ozon_realization_metrics.sql, ozon_metrics_by_sku_month,
-- ozon_metrics_by_cabinet_month_cashflow_api. Канонические вьюхи не затронуты.
--
-- Бренд — из каталога Ozon API (ozon_products, атрибут «Бренд»), по артикулу
-- продавца. Всё, что привязано к артикулу, лежит на бренде артикула точно;
-- расходы уровня кабинета раскладываются ПРОПОРЦИОНАЛЬНО ВЫРУЧКЕ бренда за
-- месяц (оценка, не данные Ozon). Пустой бренд и «Нет бренда» = название
-- кабинета, CloudSix = «Cloud Six».
--
-- Порядок накатки: ozon_product_brands → realization → xlsx → cashflow_api.
-- Применять под пользователем с правом DDL (default). Вьюхи новые.

-- ==== справочник: кабинет × артикул → бренд ====
CREATE VIEW IF NOT EXISTS ozon_product_brands AS
SELECT
    cabinet                       AS cabinet,
    offer_key                     AS offer_key,
    if(lowerUTF8(trim(coalesce(b, ''))) = '' OR lowerUTF8(trim(coalesce(b, ''))) = 'неопознанный товар' OR lowerUTF8(trim(coalesce(b, ''))) = 'нет бренда' OR lowerUTF8(trim(coalesce(b, ''))) = lowerUTF8(cabinet), if(cabinet = 'CloudSix', 'Cloud Six', cabinet), trim(coalesce(b, ''))) AS brand_key
FROM (
    SELECT cabinet, lowerUTF8(trim(offer_id)) AS offer_key, argMax(brand, loaded_at) AS b
    FROM ozon_products FINAL
    WHERE trim(offer_id) != ''
    GROUP BY cabinet, offer_key
);

ALTER TABLE ozon_product_brands COMMENT COLUMN brand_key 'Бренд артикула по каталогу Ozon: пустой и «Нет бренда» заменены названием кабинета, CloudSix = «Cloud Six». Артикула нет в каталоге — в вьюхах-потребителях тоже название кабинета.';

-- ==== реализация по брендам: из schema_ozon_realization_metrics.sql ====
CREATE VIEW IF NOT EXISTS ozon_realization_by_cabinet_brand_month AS
WITH cogs_agg AS (
    SELECT
        cabinet                                  AS cabinet,
        toStartOfMonth(stop_date)                AS month,
        brand_key                                AS brand_key,
        sum(net_qty * unit_cost)                 AS cogs_amount,
        sum(if(has_cost = 1, net_qty, 0))        AS qty_covered,
        sum(if(has_cost = 1, 0, net_qty))        AS qty_uncovered
    FROM (
        SELECT
            r.cabinet AS cabinet,
            r.stop_date AS stop_date,
            coalesce(nullIf(pbr.brand_key, ''), if(r.cabinet = 'CloudSix', 'Cloud Six', r.cabinet)) AS brand_key,
            multiIf(r.kind = 'delivery', r.quantity, r.kind = 'return', -r.quantity, 0) AS net_qty,
            coalesce(w.unit_cost, 0) AS unit_cost,
            coalesce(w.has_cost, toUInt8(0)) AS has_cost
        FROM ozon_realization AS r
        LEFT JOIN (
            SELECT sku, week_start, unit_cost, toUInt8(1) AS has_cost
            FROM wb_cogs_weekly FINAL
        ) AS w
          ON lowerUTF8(trim(r.offer_id)) = w.sku AND toMonday(r.stop_date) = w.week_start
        LEFT JOIN ozon_product_brands AS pbr
          ON pbr.cabinet = r.cabinet AND pbr.offer_key = lowerUTF8(trim(r.offer_id))
    )
    GROUP BY cabinet, month, brand_key
)
SELECT
    o.cabinet                                                    AS cabinet,
    toStartOfMonth(o.stop_date)                                  AS month,
    coalesce(nullIf(pbo.brand_key, ''), if(o.cabinet = 'CloudSix', 'Cloud Six', o.cabinet)) AS brand,

    toInt64(sumIf(quantity, kind = 'delivery')
          - sumIf(quantity, kind = 'return'))                    AS sales_qty,

    sumIf(amount + bank_coinvestment + pick_up_point_coinvestment
          + bonus, kind = 'delivery')                            AS sales_with_spp,
    sumIf(amount + bank_coinvestment + pick_up_point_coinvestment,
          kind = 'delivery')                                     AS sales_amount,
    sumIf(bonus, kind = 'delivery')                              AS spp_amount,

    -- комиссия расходом, знак как в .xlsx-модели
    -(sumIf(standard_fee, kind = 'delivery')
      - sumIf(standard_fee, kind = 'return'))                    AS commission,

    -- возвраты целиком в корректировки, расходом
    -sumIf(amount + bank_coinvestment + pick_up_point_coinvestment
           + bonus, kind = 'return')                             AS returns_corrections,

    sumIf(total, kind = 'delivery')
      - sumIf(total, kind = 'return')                            AS payable_for_goods,

    -coalesce(any(c.cogs_amount), 0)                             AS cogs,
    toInt64(coalesce(any(c.qty_covered), 0))                     AS cogs_qty_covered,
    toInt64(coalesce(any(c.qty_uncovered), 0))                   AS cogs_qty_uncovered
FROM ozon_realization AS o
LEFT JOIN ozon_product_brands AS pbo
       ON pbo.cabinet = o.cabinet AND pbo.offer_key = lowerUTF8(trim(o.offer_id))
LEFT JOIN cogs_agg AS c
       ON c.cabinet = o.cabinet AND c.month = toStartOfMonth(o.stop_date)
      AND c.brand_key = coalesce(nullIf(pbo.brand_key, ''), if(o.cabinet = 'CloudSix', 'Cloud Six', o.cabinet))
GROUP BY o.cabinet, toStartOfMonth(o.stop_date), coalesce(nullIf(pbo.brand_key, ''), if(o.cabinet = 'CloudSix', 'Cloud Six', o.cabinet))
ORDER BY cabinet, brand, month;

ALTER TABLE ozon_realization_by_cabinet_brand_month COMMENT COLUMN sales_qty 'Кол-во продаж = поставки минус возвраты (kind delivery/return). На CloudSix расходится с .xlsx на 2-4 шт в месяц.';
ALTER TABLE ozon_realization_by_cabinet_brand_month COMMENT COLUMN sales_amount 'Выручка = amount + софинансирование банка и ПВЗ, по поставкам. Софинансирование отнесено сюда, а не к СПП: проверено числом — без него расхождение с .xlsx было бы 65 994 ₽ вместо 1 026 ₽.';
ALTER TABLE ozon_realization_by_cabinet_brand_month COMMENT COLUMN spp_amount 'СПП = bonus по поставкам. Расхождение с .xlsx 999 ₽ на 6.3 млн.';
ALTER TABLE ozon_realization_by_cabinet_brand_month COMMENT COLUMN commission 'Комиссия = -standard_fee (поставки минус возвраты). Совпадает с .xlsx ТОЧНО.';
ALTER TABLE ozon_realization_by_cabinet_brand_month COMMENT COLUMN returns_corrections 'Корректировки = возвраты целиком, расходом. Разбивка у Ozon своя, поэтому с .xlsx расходится на 2 025 ₽ из 1.35 млн.';
ALTER TABLE ozon_realization_by_cabinet_brand_month COMMENT COLUMN payable_for_goods 'К перечислению за товар = total (поставки минус возвраты). Совпадает с .xlsx ТОЧНО и с payable_for_goods из cash-flow тоже.';

ALTER TABLE ozon_realization_by_cabinet_brand_month COMMENT COLUMN cogs 'Себестоимость проданного товара, ₽, знак минус (расход). (Поставки минус возвраты) в штуках по артикулу x цена единицы за неделю операции из wb_cogs_weekly. Артикулы вне справочника дают 0 — насколько занижено, видно по cogs_qty_uncovered.';
ALTER TABLE ozon_realization_by_cabinet_brand_month COMMENT COLUMN cogs_qty_covered 'Сколько единиц (поставки минус возвраты) нашли себестоимость на свою неделю. Колонка счётная, суммируется свободно.';
ALTER TABLE ozon_realization_by_cabinet_brand_month COMMENT COLUMN cogs_qty_uncovered 'Сколько единиц остались БЕЗ себестоимости и посчитаны по нулю. Ненулевое значение = себестоимость и валовая прибыль занижены, лечится дозаливкой файла СС (ingest_wb_cogs.py), а не правкой формул.';

ALTER TABLE ozon_realization_by_cabinet_brand_month COMMENT COLUMN brand 'Бренд по каталогу Ozon (ozon_product_brands): точно по артикулу; пустой и «Нет бренда» — название кабинета, CloudSix = «Cloud Six».';

-- ==== .xlsx: поверх ozon_metrics_by_sku_month ====
CREATE VIEW IF NOT EXISTS ozon_metrics_by_cabinet_brand_month AS
WITH s AS (
    -- уровень артикула из КАНОНИЧЕСКОЙ вьюхи; формулы здесь не пересчитываются
    SELECT k.cabinet AS cabinet,
           k.month AS month,
           if(k.sku = 'без артикула', '', coalesce(nullIf(pb.brand_key, ''), if(k.cabinet = 'CloudSix', 'Cloud Six', k.cabinet))) AS brand_key,
           k.sales_qty AS sales_qty,
           k.cogs_qty_covered AS cogs_qty_covered,
           k.cogs_qty_uncovered AS cogs_qty_uncovered,
           k.sales_with_spp AS sales_with_spp,
           k.sales_amount AS sales_amount,
           k.spp_amount AS spp_amount,
           k.commission AS commission,
           k.returns_corrections AS returns_corrections,
           k.payable_for_goods AS payable_for_goods,
           k.logistics_cost AS logistics_cost,
           k.last_mile_cost AS last_mile_cost,
           k.fines AS fines,
           k.surcharges AS surcharges,
           k.storage_cost AS storage_cost,
           k.promotion_cost AS promotion_cost,
           k.other_accruals AS other_accruals,
           k.payable_total AS payable_total,
           k.cogs AS cogs,
           k.gross_profit AS gross_profit
    FROM ozon_metrics_by_sku_month AS k
    LEFT JOIN ozon_product_brands AS pb
           ON pb.cabinet = k.cabinet AND pb.offer_key = lowerUTF8(trim(k.sku))
),
att AS (
    -- привязано к артикулу — на бренд артикула ТОЧНО
    SELECT cabinet, month, brand_key,
           sum(sales_qty) AS sales_qty,
           sum(cogs_qty_covered) AS cogs_qty_covered,
           sum(cogs_qty_uncovered) AS cogs_qty_uncovered,
           sum(sales_with_spp) AS sales_with_spp,
           sum(sales_amount) AS sales_amount,
           sum(spp_amount) AS spp_amount,
           sum(commission) AS commission,
           sum(returns_corrections) AS returns_corrections,
           sum(payable_for_goods) AS payable_for_goods,
           sum(logistics_cost) AS logistics_cost,
           sum(last_mile_cost) AS last_mile_cost,
           sum(fines) AS fines,
           sum(surcharges) AS surcharges,
           sum(storage_cost) AS storage_cost,
           sum(promotion_cost) AS promotion_cost,
           sum(other_accruals) AS other_accruals,
           sum(payable_total) AS payable_total,
           sum(cogs) AS cogs,
           sum(gross_profit) AS gross_profit
    FROM s
    WHERE brand_key != ''
    GROUP BY cabinet, month, brand_key
),
un AS (
    -- начисления без артикула (Ozon относит их на кабинет целиком) — будут разложены
    SELECT cabinet, month,
           sum(sales_with_spp) AS sales_with_spp,
           sum(sales_amount) AS sales_amount,
           sum(spp_amount) AS spp_amount,
           sum(commission) AS commission,
           sum(returns_corrections) AS returns_corrections,
           sum(payable_for_goods) AS payable_for_goods,
           sum(logistics_cost) AS logistics_cost,
           sum(last_mile_cost) AS last_mile_cost,
           sum(fines) AS fines,
           sum(surcharges) AS surcharges,
           sum(storage_cost) AS storage_cost,
           sum(promotion_cost) AS promotion_cost,
           sum(other_accruals) AS other_accruals,
           sum(payable_total) AS payable_total,
           sum(cogs) AS cogs,
           sum(gross_profit) AS gross_profit
    FROM s
    WHERE brand_key = ''
    GROUP BY cabinet, month
),
wt AS (
    SELECT cabinet, month, sum(greatest(sales_amount, 0)) AS wsum
    FROM att
    GROUP BY cabinet, month
),
recv AS (
    -- получатели доли: бренды с положительной выручкой пропорционально ей…
    SELECT a.cabinet AS cabinet, a.month AS month, a.brand_key AS brand_key,
           greatest(a.sales_amount, 0) / t.wsum AS share
    FROM att AS a
    INNER JOIN wt AS t ON t.cabinet = a.cabinet AND t.month = a.month
    WHERE t.wsum > 0
    UNION ALL
    -- …а если выручки нет — всё на строку с названием кабинета
    SELECT u.cabinet AS cabinet, u.month AS month, if(u.cabinet = 'CloudSix', 'Cloud Six', u.cabinet) AS brand_key,
           toFloat64(1) AS share
    FROM un AS u
    LEFT JOIN wt AS t ON t.cabinet = u.cabinet AND t.month = u.month
    WHERE coalesce(t.wsum, 0) = 0
),
all_rows AS (
    SELECT cabinet, month, brand_key, sales_qty, cogs_qty_covered, cogs_qty_uncovered, sales_with_spp, sales_amount, spp_amount, commission, returns_corrections, payable_for_goods, logistics_cost, last_mile_cost, fines, surcharges, storage_cost, promotion_cost, other_accruals, payable_total, cogs, gross_profit FROM att
    UNION ALL
    SELECT r.cabinet AS cabinet, r.month AS month, r.brand_key AS brand_key,
           toInt64(0) AS sales_qty,
           toInt64(0) AS cogs_qty_covered,
           toInt64(0) AS cogs_qty_uncovered,
           u.sales_with_spp * r.share AS sales_with_spp,
           u.sales_amount * r.share AS sales_amount,
           u.spp_amount * r.share AS spp_amount,
           u.commission * r.share AS commission,
           u.returns_corrections * r.share AS returns_corrections,
           u.payable_for_goods * r.share AS payable_for_goods,
           u.logistics_cost * r.share AS logistics_cost,
           u.last_mile_cost * r.share AS last_mile_cost,
           u.fines * r.share AS fines,
           u.surcharges * r.share AS surcharges,
           u.storage_cost * r.share AS storage_cost,
           u.promotion_cost * r.share AS promotion_cost,
           u.other_accruals * r.share AS other_accruals,
           u.payable_total * r.share AS payable_total,
           u.cogs * r.share AS cogs,
           u.gross_profit * r.share AS gross_profit
    FROM recv AS r
    INNER JOIN un AS u ON u.cabinet = r.cabinet AND u.month = r.month
)
SELECT
    cabinet                  AS cabinet,
    month                    AS month,
    brand_key                AS brand,
    toInt64(sum(sales_qty)) AS sales_qty,
    toInt64(sum(cogs_qty_covered)) AS cogs_qty_covered,
    toInt64(sum(cogs_qty_uncovered)) AS cogs_qty_uncovered,
    sum(sales_with_spp) AS sales_with_spp,
    sum(sales_amount) AS sales_amount,
    sum(spp_amount) AS spp_amount,
    sum(commission) AS commission,
    sum(returns_corrections) AS returns_corrections,
    sum(payable_for_goods) AS payable_for_goods,
    sum(logistics_cost) AS logistics_cost,
    sum(last_mile_cost) AS last_mile_cost,
    sum(fines) AS fines,
    sum(surcharges) AS surcharges,
    sum(storage_cost) AS storage_cost,
    sum(promotion_cost) AS promotion_cost,
    sum(other_accruals) AS other_accruals,
    sum(payable_total) AS payable_total,
    sum(cogs) AS cogs,
    sum(gross_profit) AS gross_profit
FROM all_rows
GROUP BY cabinet, month, brand_key
ORDER BY cabinet, brand, month;

ALTER TABLE ozon_metrics_by_cabinet_brand_month COMMENT COLUMN brand 'Бренд по каталогу Ozon (ozon_product_brands). Начисления с артикулом — на бренд артикула точно; начисления без артикула (расходы кабинета) разложены по брендам пропорционально выручке бренда за месяц (оценка). Пустой и «Нет бренда» — название кабинета, CloudSix = «Cloud Six».';

-- ==== API: cash-flow, разложенный по брендам ====
CREATE VIEW IF NOT EXISTS ozon_metrics_by_cabinet_brand_month_cashflow_api AS
WITH rb AS (
    SELECT cabinet, month, brand, sales_amount, payable_for_goods
    FROM ozon_realization_by_cabinet_brand_month
),
wt AS (
    SELECT cabinet, month, sum(greatest(sales_amount, 0)) AS wsum
    FROM rb
    GROUP BY cabinet, month
),
parts AS (
    -- есть реализация с выручкой: «К перечислению за товар» точно из реализации (она
    -- совпадает с cash-flow до рубля), расходы кабинета — по доле выручки бренда
    SELECT c.cabinet AS cabinet, c.month AS month, rb.brand AS brand,
           rb.payable_for_goods AS pfg,
           greatest(rb.sales_amount, 0) / wt.wsum AS share,
           c.logistics_cost AS raw_logistics_cost,
           c.last_mile_cost AS raw_last_mile_cost,
           c.fines AS raw_fines,
           c.surcharges AS raw_surcharges,
           c.storage_cost AS raw_storage_cost,
           c.promotion_cost AS raw_promotion_cost,
           c.other_accruals AS raw_other_accruals,
           c.unmapped AS raw_unmapped
    FROM ozon_metrics_by_cabinet_month_cashflow_api AS c
    INNER JOIN rb ON rb.cabinet = c.cabinet AND rb.month = c.month
    INNER JOIN wt ON wt.cabinet = c.cabinet AND wt.month = c.month
    WHERE wt.wsum > 0
    UNION ALL
    -- реализации (или выручки) нет — делить не по чему, всё на название кабинета
    SELECT c.cabinet AS cabinet, c.month AS month, if(c.cabinet = 'CloudSix', 'Cloud Six', c.cabinet) AS brand,
           c.payable_for_goods AS pfg,
           toFloat64(1) AS share,
           c.logistics_cost AS raw_logistics_cost,
           c.last_mile_cost AS raw_last_mile_cost,
           c.fines AS raw_fines,
           c.surcharges AS raw_surcharges,
           c.storage_cost AS raw_storage_cost,
           c.promotion_cost AS raw_promotion_cost,
           c.other_accruals AS raw_other_accruals,
           c.unmapped AS raw_unmapped
    FROM ozon_metrics_by_cabinet_month_cashflow_api AS c
    LEFT JOIN wt ON wt.cabinet = c.cabinet AND wt.month = c.month
    WHERE coalesce(wt.wsum, 0) = 0
)
SELECT
    cabinet                  AS cabinet,
    month                    AS month,
    brand                    AS brand,
    pfg                      AS payable_for_goods,
    raw_logistics_cost * share AS logistics_cost,
    raw_last_mile_cost * share AS last_mile_cost,
    raw_fines * share AS fines,
    raw_surcharges * share AS surcharges,
    raw_storage_cost * share AS storage_cost,
    raw_promotion_cost * share AS promotion_cost,
    raw_other_accruals * share AS other_accruals,
    raw_unmapped * share AS unmapped,
    pfg + (raw_logistics_cost + raw_last_mile_cost + raw_fines + raw_surcharges + raw_storage_cost + raw_promotion_cost + raw_other_accruals) * share AS payable_total
FROM parts
ORDER BY cabinet, brand, month;

ALTER TABLE ozon_metrics_by_cabinet_brand_month_cashflow_api COMMENT COLUMN brand 'Бренд по каталогу Ozon. «К перечислению за товар» — точно из реализации по бренду; логистика, последняя миля, штрафы, доплаты, хранение, продвижение, прочие начисления и нераспознанное — расходы кабинета, разложенные пропорционально выручке бренда за месяц (оценка; продвижение планируется перевести на поартикульные данные). Нет реализации — всё на название кабинета.';
