-- VIEW-слой метрик Ozon в разрезе АРТИКУЛА — КАНОНИЧЕСКИЙ источник истины
-- для Ozon-метрик, по образцу того, как это сделано у WB
-- (wb_metrics_by_sku_month, см. schema_wb_metrics_views_sku.sql).
-- С 2026-09-23 ozon_metrics_by_cabinet_month (schema_ozon_metrics_views.sql)
-- больше не считает формулы сам, а стал тонкой агрегацией
-- (GROUP BY cabinet, month, sum(...)) поверх ЭТОГО VIEW. Меняйте формулы
-- ТОЛЬКО здесь.
--
-- Формулы перенесены из ozon_metrics_by_cabinet_month дословно, включая обе
-- исторические поправки (группа "Услуги агентов"/"Услуги партнёров" после
-- переименования Ozon и перенос отрицательных строк группы "Продажи" в
-- corrections) — см. подробные комментарии в schema_ozon_metrics_views.sql,
-- здесь они не дублируются.
--
-- Проверено при переводе 2026-09-23: агрегация этого VIEW по (cabinet, month)
-- даёт побайтово те же 11 метрик, что старый независимый расчёт
-- ozon_metrics_by_cabinet_month. abs(q_ret) при переносе на уровень артикула
-- безопасен: во всех строках "Возвраты"/"Возврат выручки" qty положительный
-- (6387 строк, ни одной отрицательной), смешанных знаков внутри
-- (кабинет, месяц, артикул) нет — то есть сумма модулей равна модулю суммы.
--
-- sku — это `article` из ozon_reports (артикул ПРОДАВЦА, он же offer_id), а
-- НЕ колонка `sku` той же таблицы: там лежит числовой идентификатор товара
-- на стороне Ozon, который не бьётся ни с WB, ни со справочником
-- себестоимости. Пустые значения помечены как 'без артикула'.
--
-- ВАЖНО про 'без артикула': в отличие от WB, у Ozon это не редкий остаток, а
-- целые группы услуг. Артикул заполнен у 100% строк "Продажи"/"Возвраты"/
-- "Вознаграждение Ozon", но полностью отсутствует у "Компенсации и
-- декомпенсации" и "Прочие начисления", у 80% "Услуги FBO", 63% "Другие
-- услуги и штрафы" и 35% "Продвижение и реклама" — эти расходы Ozon
-- начисляет на кабинет целиком, а не на товар. Поэтому в разрезе артикула
-- они честно сидят в строке 'без артикула', а не размазываются по товарам
-- пропорционально чему-нибудь: такое распределение было бы выдумкой, а не
-- данными. Любая карточка поверх этого VIEW обязана группировать/фильтровать
-- по sku (и обычно по cabinet) — иначе строки разных артикулов молча
-- просуммируются.
--
-- СЕБЕСТОИМОСТЬ считается так же, как у WB: (продажи минус возвраты) в
-- штуках × себестоимость единицы за НЕДЕЛЮ начисления (toMonday(accrual_date))
-- из wb_cogs_weekly, знак минус (расход). Справочник себестоимости общий с
-- WB и заведомо проектный, а не площадочный — один и тот же товар продаётся
-- и на WB, и на Ozon по одной закупочной цене (см. schema_wb_cogs.sql).
-- Покрытие на 2026-09-23 по единицам: Torado 100%, CloudSix 99.9%,
-- Lampa 99.2%, Isonic 99.1%, NoxLab 98.9%, X-Tech 97.4% — и MaxJansen 0%
-- (этого кабинета нет в файле себестоимости вообще). Непокрытые артикулы
-- дают cogs = 0, видно по cogs_qty_covered/cogs_qty_uncovered.

CREATE VIEW IF NOT EXISTS ozon_metrics_by_sku_month AS
WITH base AS (
    SELECT
        cabinet,
        toDateTime(toStartOfMonth(accrual_date)) + INTERVAL 12 HOUR AS month,
        coalesce(nullIf(trim(article), ''), 'без артикула') AS sku,
        anyHeavy(product_name) AS product_name,

        coalesce(sumIf(qty, service_group = 'Продажи' AND accrual_type = 'Выручка'), 0) AS q_sale,
        coalesce(sumIf(qty, service_group = 'Возвраты' AND accrual_type = 'Возврат выручки'), 0) AS q_ret,

        coalesce(sumIf(total_amount, service_group = 'Продажи' AND total_amount >= 0), 0) AS sales_spp,
        coalesce(sumIf(total_amount, service_group = 'Продажи' AND accrual_type IN ('Выручка', 'Программы партнёров') AND total_amount >= 0), 0) AS sales,
        coalesce(sumIf(total_amount, service_group = 'Продажи' AND accrual_type = 'Баллы за скидки' AND total_amount >= 0), 0) AS spp,
        coalesce(sumIf(total_amount, service_group = 'Вознаграждение Ozon'), 0) AS commission,
        coalesce(sumIf(total_amount, service_group = 'Возвраты'), 0)
            + coalesce(sumIf(total_amount, service_group = 'Продажи' AND total_amount < 0), 0) AS corrections,
        coalesce(sumIf(total_amount, service_group = 'Услуги доставки'), 0) AS logistics,
        coalesce(sumIf(total_amount, service_group IN ('Услуги агентов', 'Услуги партнёров')), 0) AS last_mile,
        coalesce(sumIf(total_amount, service_group IN ('Другие услуги', 'Другие услуги и штрафы')), 0) AS fines,
        coalesce(sumIf(total_amount, service_group = 'Компенсации и декомпенсации'), 0) AS surcharges,
        coalesce(sumIf(total_amount, service_group = 'Услуги FBO'), 0) AS storage,
        coalesce(sumIf(total_amount, service_group = 'Продвижение и реклама'), 0) AS promotion,
        coalesce(sumIf(total_amount, service_group = 'Прочие начисления'), 0) AS other
    FROM ozon_reports
    WHERE accrual_date IS NOT NULL
    GROUP BY cabinet, month, sku
),
cogs_agg AS (
    SELECT
        r.cabinet AS cabinet,
        toDateTime(toStartOfMonth(r.accrual_date)) + INTERVAL 12 HOUR AS month,
        coalesce(nullIf(trim(r.article), ''), 'без артикула') AS sku,
        -- has_cost, а не проверка unit_cost на NULL: ClickHouse в LEFT JOIN
        -- подставляет 0, и настоящая нулевая цена была бы неотличима от
        -- отсутствия строки в справочнике.
        coalesce(sum(r.net_qty * w.unit_cost), 0)          AS cogs_amount,
        coalesce(sum(if(w.has_cost = 1, r.net_qty, 0)), 0) AS qty_covered,
        coalesce(sum(if(w.has_cost = 1, 0, r.net_qty)), 0) AS qty_uncovered
    FROM (
        SELECT
            cabinet,
            accrual_date,
            article,
            lowerUTF8(trim(article)) AS sku_key,
            toMonday(accrual_date) AS week_start,
            multiIf(service_group = 'Продажи'  AND accrual_type = 'Выручка',         qty,
                    service_group = 'Возвраты' AND accrual_type = 'Возврат выручки', -abs(qty),
                    0) AS net_qty
        FROM ozon_reports
        WHERE accrual_date IS NOT NULL
          AND (   (service_group = 'Продажи'  AND accrual_type = 'Выручка')
               OR (service_group = 'Возвраты' AND accrual_type = 'Возврат выручки'))
    ) r
    LEFT JOIN (
        SELECT sku, week_start, unit_cost, toUInt8(1) AS has_cost
        FROM wb_cogs_weekly FINAL
    ) w ON r.sku_key = w.sku AND r.week_start = w.week_start
    GROUP BY cabinet, month, sku
)
SELECT
    base.cabinet                                     AS cabinet,
    base.month                                        AS month,
    base.sku                                          AS sku,
    base.product_name                                 AS product_name,
    toInt32(q_sale - abs(q_ret))                      AS sales_qty,
    sales_spp                                         AS sales_with_spp,
    sales                                             AS sales_amount,
    spp                                               AS spp_amount,
    commission                                        AS commission,
    corrections                                       AS returns_corrections,
    (sales + spp + commission + corrections)          AS payable_for_goods,
    logistics                                         AS logistics_cost,
    last_mile                                         AS last_mile_cost,
    fines                                             AS fines,
    surcharges                                        AS surcharges,
    storage                                           AS storage_cost,
    promotion                                         AS promotion_cost,
    other                                              AS other_accruals,
    (
        sales + spp + commission + corrections
        + logistics + last_mile + fines + surcharges + storage + promotion + other
    )                                                  AS payable_total,
    (-coalesce(c.cogs_amount, 0))                      AS cogs,
    (
        sales + spp + commission + corrections
        + logistics + last_mile + fines + surcharges + storage + promotion + other
        - coalesce(c.cogs_amount, 0)
    )                                                  AS gross_profit,
    toInt64(coalesce(c.qty_covered, 0))                AS cogs_qty_covered,
    toInt64(coalesce(c.qty_uncovered, 0))              AS cogs_qty_uncovered
FROM base
LEFT JOIN cogs_agg c
    ON base.cabinet = c.cabinet AND base.month = c.month AND base.sku = c.sku
ORDER BY cabinet, sku, month;

ALTER TABLE ozon_metrics_by_sku_month COMMENT COLUMN sku 'Артикул ПРОДАВЦА (article из ozon_reports, он же offer_id), пустые значения — ''без артикула''. Не путать с колонкой sku той же таблицы — там числовой идентификатор товара на стороне Ozon. Строка ''без артикула'' содержит account-level расходы (реклама, FBO, компенсации, прочие начисления), которые Ozon начисляет на кабинет целиком и которые намеренно НЕ размазаны по товарам.';
ALTER TABLE ozon_metrics_by_sku_month COMMENT COLUMN product_name 'Название товара — anyHeavy(product_name) по артикулу (самое частое написание за период).';
ALTER TABLE ozon_metrics_by_sku_month COMMENT COLUMN cogs 'Себестоимость проданного товара, ₽, знак инвертирован (расход). (Продажи минус возвраты) в штуках × себестоимость единицы за НЕДЕЛЮ начисления из wb_cogs_weekly (справочник общий с WB, он проектный). Артикулы вне справочника дают 0 — насколько занижено, видно по cogs_qty_uncovered. В payable_total НЕ входит.';
ALTER TABLE ozon_metrics_by_sku_month COMMENT COLUMN gross_profit 'Валовая прибыль = payable_total + cogs (cogs отрицательный).';
ALTER TABLE ozon_metrics_by_sku_month COMMENT COLUMN cogs_qty_covered 'Проданных единиц (продажи минус возвраты) с известной себестоимостью. Счётная колонка, суммируется свободно.';
ALTER TABLE ozon_metrics_by_sku_month COMMENT COLUMN cogs_qty_uncovered 'Проданных единиц БЕЗ себестоимости (посчитаны по нулю) — на столько занижены cogs/gross_profit. Лечится дозаливкой файла себестоимости (ingest_wb_cogs.py), а не правкой формул. Долю покрытия считайте как covered/(covered+uncovered) в карточке — готовой колонки-доли нет намеренно, её нельзя суммировать по месяцам.';
