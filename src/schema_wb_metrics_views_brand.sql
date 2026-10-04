-- СГЕНЕРИРОВАННЫЙ ФАЙЛ. Не правьте руками.
--
-- Источник: schema_wb_metrics_views_sku.sql + schema_wb_metrics_views.sql
-- Генератор: scripts/gen_wb_metrics_brand_views.py
--
-- Те же метрики WB, что в канонических вьюхах, с дополнительным измерением
-- «бренд» (строка отчёта: wb_reports.brand для .xlsx, brand у API). Пустой бренд
-- и «Неопознанный Товар» = название кабинета (CloudSix → «Cloud Six»), без
-- перераспределения по артикулу, см. brand_expr(). Формула взята из
-- канонических файлов дословно; изменены только группировка и ключ джойна
-- себестоимости. Канонические вьюхи не затронуты.
--
-- Применять на проде ТОЛЬКО под пользователем с правом DDL (default), порядок:
-- sku-вьюха, потом кабинетная (она читает sku-вьюху). Вьюхи новые, поэтому
-- CREATE VIEW IF NOT EXISTS ничего существующего не перезаписывает.
--
-- Правите формулу — правьте КАНОНИЧЕСКИЙ файл и прогоняйте генератор.

-- ==== .xlsx: из schema_wb_metrics_views_sku.sql ====
CREATE VIEW IF NOT EXISTS wb_metrics_by_sku_brand_month AS
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
        if(lowerUTF8(trim(coalesce(brand, ''))) = '' OR lowerUTF8(trim(coalesce(brand, ''))) = 'неопознанный товар' OR lowerUTF8(trim(coalesce(brand, ''))) = lowerUTF8(cabinet), if(cabinet = 'CloudSix', 'Cloud Six', cabinet), trim(coalesce(brand, ''))) AS brand_key,
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

        -- Логистика — по ВСЕМ строкам, без фильтра по payment_reason (как в
        -- сводном отчёте, см. ПРАВКУ 2026-09-29 в заголовке): с 2026-09-01 WB
        -- проводит её операцией "Доставка", а не "Логистика".
        coalesce(sumIf(delivery_service_cost,
            logistics_fines_corrections_type LIKE '%К клиенту%'), 0) AS direct_logistics,
        coalesce(sumIf(delivery_service_cost,
            logistics_fines_corrections_type NOT LIKE '%К клиенту%' OR logistics_fines_corrections_type IS NULL), 0) AS reverse_logistics,

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

        coalesce(sum(loyalty_program_cost), 0)
          - 2 * coalesce(sumIf(loyalty_program_cost, document_type = 'Возврат'), 0) AS sum_loyalty_cost,
        coalesce(sum(loyalty_points_deducted), 0)
          - 2 * coalesce(sumIf(loyalty_points_deducted, document_type = 'Возврат'), 0) AS sum_loyalty_points
    FROM wb_reports
    WHERE sale_date IS NOT NULL
    GROUP BY cabinet, month, sku, brand_key
),
cogs_agg AS (
    SELECT
        r.cabinet AS cabinet,
        if(lowerUTF8(trim(coalesce(r.brand, ''))) = '' OR lowerUTF8(trim(coalesce(r.brand, ''))) = 'неопознанный товар' OR lowerUTF8(trim(coalesce(r.brand, ''))) = lowerUTF8(r.cabinet), if(r.cabinet = 'CloudSix', 'Cloud Six', r.cabinet), trim(coalesce(r.brand, ''))) AS brand_key,
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
            brand,
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
    GROUP BY cabinet, month, sku, brand_key
)
SELECT
    cabinet                                               AS cabinet,
    brand_key                                              AS brand,
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
    (-sum_loyalty_cost - sum_loyalty_points) AS wibes_discount,
    (-sum_promo)                                           AS promotion_cost,
    (
      (ah_sale - ah_ret) + (corr_sale - corr_ret) + (-direct_logistics) + (-reverse_logistics)
      + (-sum_fines) + (-sum_correction) + (-sum_storage) + (-sum_acceptance) + (-sum_deductions)
      + (-sum_loyalty_cost - sum_loyalty_points) + (-sum_promo)
    )                                                       AS payable_total,
    (-coalesce(c.cogs_amount, 0))                           AS cogs,
    (
      (ah_sale - ah_ret) + (corr_sale - corr_ret) + (-direct_logistics) + (-reverse_logistics)
      + (-sum_fines) + (-sum_correction) + (-sum_storage) + (-sum_acceptance) + (-sum_deductions)
      + (-sum_loyalty_cost - sum_loyalty_points) + (-sum_promo)
      - coalesce(c.cogs_amount, 0)
    )                                                       AS gross_profit,
    toInt64(coalesce(c.qty_covered, 0))                     AS cogs_qty_covered,
    toInt64(coalesce(c.qty_uncovered, 0))                   AS cogs_qty_uncovered
FROM base
LEFT JOIN cogs_agg c
    ON base.cabinet = c.cabinet AND base.month = c.month AND base.sku = c.sku
   AND base.brand_key = c.brand_key
ORDER BY cabinet, brand, sku, month;

ALTER TABLE wb_metrics_by_sku_brand_month COMMENT COLUMN sku 'Артикул продавца (supplier_article из wb_reports), пустые значения — ''без артикула''. Доп. измерение поверх той же формулы, что wb_metrics_by_cabinet_month.';
ALTER TABLE wb_metrics_by_sku_brand_month COMMENT COLUMN product_name 'Название товара — anyHeavy(product_name) по артикулу (самое частое встреченное название, на случай расхождений в написании за разные периоды).';
ALTER TABLE wb_metrics_by_sku_brand_month COMMENT COLUMN sales_corrections 'Корректировки продаж, ₽ — payable_to_seller по строкам, payment_reason которых НЕ входит в белый список cs_k_types ("Коррекция продаж", "Корректировка эквайринга", "Услуга платная доставка"). Знак по document_type: Продажа плюсом, Возврат минусом. Входит в payable_for_goods — до 2026-09-27 эти деньги терялись целиком. Внешний адаптер считает их иначе (прибавляет Возвраты, а не вычитает) и со сводным отчётом WB не сходится, наша формула сходится — см. заголовок файла.';
ALTER TABLE wb_metrics_by_sku_brand_month COMMENT COLUMN payable_for_goods 'К перечислению за товар = (payable_to_seller продажа минус возврат по cs_k_types) + sales_corrections. Тождественно равно "payable_to_seller по ВСЕМ строкам, Продажа минус Возврат" — то есть ровно формуле сводного отчёта WB (reconciliation_rules_wb.yaml, правило "К перечислению за товар"), diff = 0.00 на всех 66 отчётах CloudSix.';
ALTER TABLE wb_metrics_by_sku_brand_month COMMENT COLUMN cogs 'Себестоимость проданного товара, ₽, знак инвертирован (расход, как штрафы и логистика). Считается как (продажи минус возвраты) в штуках × себестоимость единицы за НЕДЕЛЮ операции из wb_cogs_weekly. Артикулы, которых нет в справочнике себестоимости, дают 0 — насколько цифра занижена, видно по cogs_qty_uncovered. В payable_total НЕ входит.';
ALTER TABLE wb_metrics_by_sku_brand_month COMMENT COLUMN gross_profit 'Валовая прибыль = payable_total + cogs (cogs отрицательный). Занижена ровно настолько, насколько не покрыт справочник себестоимости — смотрите cogs_qty_uncovered рядом.';
ALTER TABLE wb_metrics_by_sku_brand_month COMMENT COLUMN cogs_qty_covered 'Сколько проданных единиц (продажи минус возвраты) нашли себестоимость на свою неделю. Колонка счётная, суммируется по месяцам и артикулам свободно.';
ALTER TABLE wb_metrics_by_sku_brand_month COMMENT COLUMN cogs_qty_uncovered 'Сколько проданных единиц (продажи минус возвраты) остались БЕЗ себестоимости и посчитаны по нулю. Ненулевое значение = cogs/gross_profit занижены, лечится дозаливкой файла себестоимости (ingest_wb_cogs.py), а не правкой формул. Процент покрытия считайте как covered/(covered+uncovered) в карточке — готовой колонки-доли здесь нет намеренно, такую долю нельзя суммировать по месяцам.';

-- ==== .xlsx: из schema_wb_metrics_views.sql ====
CREATE VIEW IF NOT EXISTS wb_metrics_by_cabinet_brand_month AS
SELECT
    cabinet                          AS cabinet,
    brand                             AS brand,
    month                             AS month,
    sum(sales_qty)                   AS sales_qty,
    sum(sales_amount)                AS sales_amount,
    sum(spp_amount)                  AS spp_amount,
    sum(wb_commission)               AS wb_commission,
    sum(sales_corrections)           AS sales_corrections,
    sum(payable_for_goods)           AS payable_for_goods,
    sum(logistics_direct)            AS logistics_direct,
    sum(logistics_reverse)           AS logistics_reverse,
    sum(fines)                       AS fines,
    sum(commission_correction)       AS commission_correction,
    sum(storage_cost)                AS storage_cost,
    sum(acceptance_cost)             AS acceptance_cost,
    sum(deductions)                  AS deductions,
    sum(wibes_discount)              AS wibes_discount,
    sum(promotion_cost)              AS promotion_cost,
    sum(payable_total)               AS payable_total,
    sum(cogs)                        AS cogs,
    sum(gross_profit)                AS gross_profit,
    sum(cogs_qty_covered)            AS cogs_qty_covered,
    sum(cogs_qty_uncovered)          AS cogs_qty_uncovered
FROM wb_metrics_by_sku_brand_month
GROUP BY cabinet, brand, month
ORDER BY cabinet, brand, month;

ALTER TABLE wb_metrics_by_cabinet_brand_month COMMENT COLUMN cabinet 'Идентификатор личного кабинета WB (строка), связывается с project_cabinets.cabinet/brand_cabinets.cabinet при platform=''wb''. Один кабинет может быть привязан к нескольким проектам/брендам.';
ALTER TABLE wb_metrics_by_cabinet_brand_month COMMENT COLUMN month 'Начало месяца продажи (по sale_date из wb_reports), время 12:00 — намеренно не 00:00, чтобы Report Timezone в Metabase не сдвигал 1-е число на конец предыдущего месяца.';
ALTER TABLE wb_metrics_by_cabinet_brand_month COMMENT COLUMN sales_qty 'Количество проданных единиц минус возвраты (qty), по payment_reason=продажа/возврат. Формула — в wb_metrics_by_sku_brand_month, здесь просто сумма по всем артикулам.';
ALTER TABLE wb_metrics_by_cabinet_brand_month COMMENT COLUMN sales_amount 'Продажи в деньгах (wb_realized_amount), продажа минус возврат, только валидные payment_reason из cs_k_types. Формула — в wb_metrics_by_sku_brand_month.';
ALTER TABLE wb_metrics_by_cabinet_brand_month COMMENT COLUMN spp_amount 'СПП (скидка постоянного покупателя) = розничная цена с учётом СПП минус фактические продажи. Формула — в wb_metrics_by_sku_brand_month.';
ALTER TABLE wb_metrics_by_cabinet_brand_month COMMENT COLUMN wb_commission 'Комиссия Wildberries = розничная цена с СПП минус сумма к перечислению продавцу. Формула — в wb_metrics_by_sku_brand_month.';
ALTER TABLE wb_metrics_by_cabinet_brand_month COMMENT COLUMN sales_corrections 'Корректировки продаж — payable_to_seller по строкам вне белого списка cs_k_types ("Коррекция продаж", "Корректировка эквайринга", "Услуга платная доставка"), знак по document_type. Входит в payable_for_goods. Добавлена 2026-09-27, до этого терялась. Формула — в wb_metrics_by_sku_brand_month.';
ALTER TABLE wb_metrics_by_cabinet_brand_month COMMENT COLUMN payable_for_goods 'К перечислению за товар (payable_to_seller), продажа минус возврат, ВКЛЮЧАЯ sales_corrections — тождественно формуле сводного отчёта WB (reconciliation_rules_wb.yaml). Формула — в wb_metrics_by_sku_brand_month.';
ALTER TABLE wb_metrics_by_cabinet_brand_month COMMENT COLUMN logistics_direct 'Логистика "к клиенту" (прямая), по всем строкам — с 2026-09 WB проводит её операцией "Доставка". Формула — в wb_metrics_by_sku_brand_month.';
ALTER TABLE wb_metrics_by_cabinet_brand_month COMMENT COLUMN logistics_reverse 'Логистика обратная (не "к клиенту" или тип не указан). Формула — в wb_metrics_by_sku_brand_month.';
ALTER TABLE wb_metrics_by_cabinet_brand_month COMMENT COLUMN fines 'Штрафы WB (total_fines), знак инвертирован (расход). Формула — в wb_metrics_by_sku_brand_month.';
ALTER TABLE wb_metrics_by_cabinet_brand_month COMMENT COLUMN commission_correction 'Доплаты — из wb_commission_correction ("Корректировка Вознаграждения Вайлдберриз"). Формула — в wb_metrics_by_sku_brand_month.';
ALTER TABLE wb_metrics_by_cabinet_brand_month COMMENT COLUMN storage_cost 'Хранение (storage_cost), знак инвертирован (расход). Формула — в wb_metrics_by_sku_brand_month.';
ALTER TABLE wb_metrics_by_cabinet_brand_month COMMENT COLUMN acceptance_cost 'Платная приёмка — из acceptance_operations ("Операции на приемке"). Формула — в wb_metrics_by_sku_brand_month.';
ALTER TABLE wb_metrics_by_cabinet_brand_month COMMENT COLUMN deductions 'Удержание (deductions) за вычетом строк, относящихся к продвижению. Формула — в wb_metrics_by_sku_brand_month.';
ALTER TABLE wb_metrics_by_cabinet_brand_month COMMENT COLUMN wibes_discount 'Скидка Wibes = −(стоимость участия в программе лояльности + удержанные баллы). Компенсацию скидки НЕ содержит с 2026-09-29: она уже внутри К перечислению за товар. Формула — в wb_metrics_by_sku_brand_month.';
ALTER TABLE wb_metrics_by_cabinet_brand_month COMMENT COLUMN promotion_cost '"Продвижение WB"/"Продвижение ВБ" объединены в одну метрику. Формула — в wb_metrics_by_sku_brand_month.';
ALTER TABLE wb_metrics_by_cabinet_brand_month COMMENT COLUMN payable_total 'Итог "К перечислению" = payable_for_goods (с корректировками продаж) + логистика + штрафы + доплаты + хранение + приёмка + удержание + скидка Wibes + продвижение. Тождественно равен "Итого к оплате" недельного сводного отчёта WB (проверено на 550 отчётах 2026 года). Себестоимость сюда НЕ входит — на этой метрике стоят сверки. Формула — в wb_metrics_by_sku_brand_month.';
ALTER TABLE wb_metrics_by_cabinet_brand_month COMMENT COLUMN cogs 'Себестоимость проданного товара, ₽, знак инвертирован (расход). Сопоставляется поартикульно по неделе операции из wb_cogs_weekly. Формула — в wb_metrics_by_sku_brand_month.';
ALTER TABLE wb_metrics_by_cabinet_brand_month COMMENT COLUMN gross_profit 'Валовая прибыль = payable_total + cogs. Формула — в wb_metrics_by_sku_brand_month.';
ALTER TABLE wb_metrics_by_cabinet_brand_month COMMENT COLUMN cogs_qty_covered 'Проданных единиц с известной себестоимостью. Формула — в wb_metrics_by_sku_brand_month.';
ALTER TABLE wb_metrics_by_cabinet_brand_month COMMENT COLUMN cogs_qty_uncovered 'Проданных единиц БЕЗ себестоимости (посчитаны по нулю) — на столько занижены cogs/gross_profit. Формула — в wb_metrics_by_sku_brand_month.';

ALTER TABLE wb_metrics_by_sku_brand_month COMMENT COLUMN brand 'Бренд строки отчёта (brand); пустой бренд и «Неопознанный Товар» — название кабинета, кабинет CloudSix везде «Cloud Six», без перераспределения по артикулу. Один артикул может встречаться под несколькими брендами (бренд берётся из строки, а не из справочника).';
ALTER TABLE wb_metrics_by_cabinet_brand_month COMMENT COLUMN brand 'Бренд строки отчёта (brand); пустой бренд и «Неопознанный Товар» — название кабинета, кабинет CloudSix везде «Cloud Six», без перераспределения по артикулу. Один артикул может встречаться под несколькими брендами (бренд берётся из строки, а не из справочника).';

-- ==== API: из schema_wb_metrics_views_sku.sql ====
CREATE VIEW IF NOT EXISTS wb_metrics_by_sku_brand_month_api AS
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
        if(lowerUTF8(trim(coalesce(brand, ''))) = '' OR lowerUTF8(trim(coalesce(brand, ''))) = 'неопознанный товар' OR lowerUTF8(trim(coalesce(brand, ''))) = lowerUTF8(cabinet), if(cabinet = 'CloudSix', 'Cloud Six', cabinet), trim(coalesce(brand, ''))) AS brand_key,
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

        -- Логистика — по ВСЕМ строкам, без фильтра по payment_reason (как в
        -- сводном отчёте, см. ПРАВКУ 2026-09-29 в заголовке): с 2026-09-01 WB
        -- проводит её операцией "Доставка", а не "Логистика".
        coalesce(sumIf(delivery_service_cost,
            logistics_fines_corrections_type LIKE '%К клиенту%'), 0) AS direct_logistics,
        coalesce(sumIf(delivery_service_cost,
            logistics_fines_corrections_type NOT LIKE '%К клиенту%' OR logistics_fines_corrections_type IS NULL), 0) AS reverse_logistics,

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

        coalesce(sum(loyalty_program_cost), 0)
          - 2 * coalesce(sumIf(loyalty_program_cost, document_type = 'Возврат'), 0) AS sum_loyalty_cost,
        coalesce(sum(loyalty_points_deducted), 0)
          - 2 * coalesce(sumIf(loyalty_points_deducted, document_type = 'Возврат'), 0) AS sum_loyalty_points
    FROM wb_api_realization_as_reports
    WHERE sale_date IS NOT NULL
    GROUP BY cabinet, month, sku, brand_key
),
cogs_agg AS (
    SELECT
        r.cabinet AS cabinet,
        if(lowerUTF8(trim(coalesce(r.brand, ''))) = '' OR lowerUTF8(trim(coalesce(r.brand, ''))) = 'неопознанный товар' OR lowerUTF8(trim(coalesce(r.brand, ''))) = lowerUTF8(r.cabinet), if(r.cabinet = 'CloudSix', 'Cloud Six', r.cabinet), trim(coalesce(r.brand, ''))) AS brand_key,
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
            brand,
            sale_date,
            supplier_article,
            lowerUTF8(trim(supplier_article)) AS sku_key,
            toMonday(sale_date) AS week_start,
            multiIf(lowerUTF8(trim(payment_reason)) = 'продажа', qty,
                    lowerUTF8(trim(payment_reason)) = 'возврат', -qty,
                    0) AS net_qty
        FROM wb_api_realization_as_reports
        WHERE sale_date IS NOT NULL
          AND lowerUTF8(trim(payment_reason)) IN ('продажа', 'возврат')
    ) r
    LEFT JOIN (
        SELECT sku, week_start, unit_cost, toUInt8(1) AS has_cost
        FROM wb_cogs_weekly FINAL
    ) w ON r.sku_key = w.sku AND r.week_start = w.week_start
    GROUP BY cabinet, month, sku, brand_key
)
SELECT
    cabinet                                               AS cabinet,
    brand_key                                              AS brand,
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
    (-sum_loyalty_cost - sum_loyalty_points) AS wibes_discount,
    (-sum_promo)                                           AS promotion_cost,
    (
      (ah_sale - ah_ret) + (corr_sale - corr_ret) + (-direct_logistics) + (-reverse_logistics)
      + (-sum_fines) + (-sum_correction) + (-sum_storage) + (-sum_acceptance) + (-sum_deductions)
      + (-sum_loyalty_cost - sum_loyalty_points) + (-sum_promo)
    )                                                       AS payable_total,
    (-coalesce(c.cogs_amount, 0))                           AS cogs,
    (
      (ah_sale - ah_ret) + (corr_sale - corr_ret) + (-direct_logistics) + (-reverse_logistics)
      + (-sum_fines) + (-sum_correction) + (-sum_storage) + (-sum_acceptance) + (-sum_deductions)
      + (-sum_loyalty_cost - sum_loyalty_points) + (-sum_promo)
      - coalesce(c.cogs_amount, 0)
    )                                                       AS gross_profit,
    toInt64(coalesce(c.qty_covered, 0))                     AS cogs_qty_covered,
    toInt64(coalesce(c.qty_uncovered, 0))                   AS cogs_qty_uncovered
FROM base
LEFT JOIN cogs_agg c
    ON base.cabinet = c.cabinet AND base.month = c.month AND base.sku = c.sku
   AND base.brand_key = c.brand_key
ORDER BY cabinet, brand, sku, month;

ALTER TABLE wb_metrics_by_sku_brand_month_api COMMENT COLUMN sku 'Артикул продавца (supplier_article из wb_reports), пустые значения — ''без артикула''. Доп. измерение поверх той же формулы, что wb_metrics_by_cabinet_month.';
ALTER TABLE wb_metrics_by_sku_brand_month_api COMMENT COLUMN product_name 'Название товара — anyHeavy(product_name) по артикулу (самое частое встреченное название, на случай расхождений в написании за разные периоды).';
ALTER TABLE wb_metrics_by_sku_brand_month_api COMMENT COLUMN sales_corrections 'Корректировки продаж, ₽ — payable_to_seller по строкам, payment_reason которых НЕ входит в белый список cs_k_types ("Коррекция продаж", "Корректировка эквайринга", "Услуга платная доставка"). Знак по document_type: Продажа плюсом, Возврат минусом. Входит в payable_for_goods — до 2026-09-27 эти деньги терялись целиком. Внешний адаптер считает их иначе (прибавляет Возвраты, а не вычитает) и со сводным отчётом WB не сходится, наша формула сходится — см. заголовок файла.';
ALTER TABLE wb_metrics_by_sku_brand_month_api COMMENT COLUMN payable_for_goods 'К перечислению за товар = (payable_to_seller продажа минус возврат по cs_k_types) + sales_corrections. Тождественно равно "payable_to_seller по ВСЕМ строкам, Продажа минус Возврат" — то есть ровно формуле сводного отчёта WB (reconciliation_rules_wb.yaml, правило "К перечислению за товар"), diff = 0.00 на всех 66 отчётах CloudSix.';
ALTER TABLE wb_metrics_by_sku_brand_month_api COMMENT COLUMN cogs 'Себестоимость проданного товара, ₽, знак инвертирован (расход, как штрафы и логистика). Считается как (продажи минус возвраты) в штуках × себестоимость единицы за НЕДЕЛЮ операции из wb_cogs_weekly. Артикулы, которых нет в справочнике себестоимости, дают 0 — насколько цифра занижена, видно по cogs_qty_uncovered. В payable_total НЕ входит.';
ALTER TABLE wb_metrics_by_sku_brand_month_api COMMENT COLUMN gross_profit 'Валовая прибыль = payable_total + cogs (cogs отрицательный). Занижена ровно настолько, насколько не покрыт справочник себестоимости — смотрите cogs_qty_uncovered рядом.';
ALTER TABLE wb_metrics_by_sku_brand_month_api COMMENT COLUMN cogs_qty_covered 'Сколько проданных единиц (продажи минус возвраты) нашли себестоимость на свою неделю. Колонка счётная, суммируется по месяцам и артикулам свободно.';
ALTER TABLE wb_metrics_by_sku_brand_month_api COMMENT COLUMN cogs_qty_uncovered 'Сколько проданных единиц (продажи минус возвраты) остались БЕЗ себестоимости и посчитаны по нулю. Ненулевое значение = cogs/gross_profit занижены, лечится дозаливкой файла себестоимости (ingest_wb_cogs.py), а не правкой формул. Процент покрытия считайте как covered/(covered+uncovered) в карточке — готовой колонки-доли здесь нет намеренно, такую долю нельзя суммировать по месяцам.';

-- ==== API: из schema_wb_metrics_views.sql ====
CREATE VIEW IF NOT EXISTS wb_metrics_by_cabinet_brand_month_api AS
SELECT
    cabinet                          AS cabinet,
    brand                             AS brand,
    month                             AS month,
    sum(sales_qty)                   AS sales_qty,
    sum(sales_amount)                AS sales_amount,
    sum(spp_amount)                  AS spp_amount,
    sum(wb_commission)               AS wb_commission,
    sum(sales_corrections)           AS sales_corrections,
    sum(payable_for_goods)           AS payable_for_goods,
    sum(logistics_direct)            AS logistics_direct,
    sum(logistics_reverse)           AS logistics_reverse,
    sum(fines)                       AS fines,
    sum(commission_correction)       AS commission_correction,
    sum(storage_cost)                AS storage_cost,
    sum(acceptance_cost)             AS acceptance_cost,
    sum(deductions)                  AS deductions,
    sum(wibes_discount)              AS wibes_discount,
    sum(promotion_cost)              AS promotion_cost,
    sum(payable_total)               AS payable_total,
    sum(cogs)                        AS cogs,
    sum(gross_profit)                AS gross_profit,
    sum(cogs_qty_covered)            AS cogs_qty_covered,
    sum(cogs_qty_uncovered)          AS cogs_qty_uncovered
FROM wb_metrics_by_sku_brand_month_api
GROUP BY cabinet, brand, month
ORDER BY cabinet, brand, month;

ALTER TABLE wb_metrics_by_cabinet_brand_month_api COMMENT COLUMN cabinet 'Идентификатор личного кабинета WB (строка), связывается с project_cabinets.cabinet/brand_cabinets.cabinet при platform=''wb''. Один кабинет может быть привязан к нескольким проектам/брендам.';
ALTER TABLE wb_metrics_by_cabinet_brand_month_api COMMENT COLUMN month 'Начало месяца продажи (по sale_date из wb_reports), время 12:00 — намеренно не 00:00, чтобы Report Timezone в Metabase не сдвигал 1-е число на конец предыдущего месяца.';
ALTER TABLE wb_metrics_by_cabinet_brand_month_api COMMENT COLUMN sales_qty 'Количество проданных единиц минус возвраты (qty), по payment_reason=продажа/возврат. Формула — в wb_metrics_by_sku_brand_month_api, здесь просто сумма по всем артикулам.';
ALTER TABLE wb_metrics_by_cabinet_brand_month_api COMMENT COLUMN sales_amount 'Продажи в деньгах (wb_realized_amount), продажа минус возврат, только валидные payment_reason из cs_k_types. Формула — в wb_metrics_by_sku_brand_month_api.';
ALTER TABLE wb_metrics_by_cabinet_brand_month_api COMMENT COLUMN spp_amount 'СПП (скидка постоянного покупателя) = розничная цена с учётом СПП минус фактические продажи. Формула — в wb_metrics_by_sku_brand_month_api.';
ALTER TABLE wb_metrics_by_cabinet_brand_month_api COMMENT COLUMN wb_commission 'Комиссия Wildberries = розничная цена с СПП минус сумма к перечислению продавцу. Формула — в wb_metrics_by_sku_brand_month_api.';
ALTER TABLE wb_metrics_by_cabinet_brand_month_api COMMENT COLUMN sales_corrections 'Корректировки продаж — payable_to_seller по строкам вне белого списка cs_k_types ("Коррекция продаж", "Корректировка эквайринга", "Услуга платная доставка"), знак по document_type. Входит в payable_for_goods. Добавлена 2026-09-27, до этого терялась. Формула — в wb_metrics_by_sku_brand_month_api.';
ALTER TABLE wb_metrics_by_cabinet_brand_month_api COMMENT COLUMN payable_for_goods 'К перечислению за товар (payable_to_seller), продажа минус возврат, ВКЛЮЧАЯ sales_corrections — тождественно формуле сводного отчёта WB (reconciliation_rules_wb.yaml). Формула — в wb_metrics_by_sku_brand_month_api.';
ALTER TABLE wb_metrics_by_cabinet_brand_month_api COMMENT COLUMN logistics_direct 'Логистика "к клиенту" (прямая), по всем строкам — с 2026-09 WB проводит её операцией "Доставка". Формула — в wb_metrics_by_sku_brand_month_api.';
ALTER TABLE wb_metrics_by_cabinet_brand_month_api COMMENT COLUMN logistics_reverse 'Логистика обратная (не "к клиенту" или тип не указан). Формула — в wb_metrics_by_sku_brand_month_api.';
ALTER TABLE wb_metrics_by_cabinet_brand_month_api COMMENT COLUMN fines 'Штрафы WB (total_fines), знак инвертирован (расход). Формула — в wb_metrics_by_sku_brand_month_api.';
ALTER TABLE wb_metrics_by_cabinet_brand_month_api COMMENT COLUMN commission_correction 'Доплаты — из wb_commission_correction ("Корректировка Вознаграждения Вайлдберриз"). Формула — в wb_metrics_by_sku_brand_month_api.';
ALTER TABLE wb_metrics_by_cabinet_brand_month_api COMMENT COLUMN storage_cost 'Хранение (storage_cost), знак инвертирован (расход). Формула — в wb_metrics_by_sku_brand_month_api.';
ALTER TABLE wb_metrics_by_cabinet_brand_month_api COMMENT COLUMN acceptance_cost 'Платная приёмка — из acceptance_operations ("Операции на приемке"). Формула — в wb_metrics_by_sku_brand_month_api.';
ALTER TABLE wb_metrics_by_cabinet_brand_month_api COMMENT COLUMN deductions 'Удержание (deductions) за вычетом строк, относящихся к продвижению. Формула — в wb_metrics_by_sku_brand_month_api.';
ALTER TABLE wb_metrics_by_cabinet_brand_month_api COMMENT COLUMN wibes_discount 'Скидка Wibes = −(стоимость участия в программе лояльности + удержанные баллы). Компенсацию скидки НЕ содержит с 2026-09-29: она уже внутри К перечислению за товар. Формула — в wb_metrics_by_sku_brand_month_api.';
ALTER TABLE wb_metrics_by_cabinet_brand_month_api COMMENT COLUMN promotion_cost '"Продвижение WB"/"Продвижение ВБ" объединены в одну метрику. Формула — в wb_metrics_by_sku_brand_month_api.';
ALTER TABLE wb_metrics_by_cabinet_brand_month_api COMMENT COLUMN payable_total 'Итог "К перечислению" = payable_for_goods (с корректировками продаж) + логистика + штрафы + доплаты + хранение + приёмка + удержание + скидка Wibes + продвижение. Тождественно равен "Итого к оплате" недельного сводного отчёта WB (проверено на 550 отчётах 2026 года). Себестоимость сюда НЕ входит — на этой метрике стоят сверки. Формула — в wb_metrics_by_sku_brand_month_api.';
ALTER TABLE wb_metrics_by_cabinet_brand_month_api COMMENT COLUMN cogs 'Себестоимость проданного товара, ₽, знак инвертирован (расход). Сопоставляется поартикульно по неделе операции из wb_cogs_weekly. Формула — в wb_metrics_by_sku_brand_month_api.';
ALTER TABLE wb_metrics_by_cabinet_brand_month_api COMMENT COLUMN gross_profit 'Валовая прибыль = payable_total + cogs. Формула — в wb_metrics_by_sku_brand_month_api.';
ALTER TABLE wb_metrics_by_cabinet_brand_month_api COMMENT COLUMN cogs_qty_covered 'Проданных единиц с известной себестоимостью. Формула — в wb_metrics_by_sku_brand_month_api.';
ALTER TABLE wb_metrics_by_cabinet_brand_month_api COMMENT COLUMN cogs_qty_uncovered 'Проданных единиц БЕЗ себестоимости (посчитаны по нулю) — на столько занижены cogs/gross_profit. Формула — в wb_metrics_by_sku_brand_month_api.';

ALTER TABLE wb_metrics_by_sku_brand_month_api COMMENT COLUMN brand 'Бренд строки отчёта (brand); пустой бренд и «Неопознанный Товар» — название кабинета, кабинет CloudSix везде «Cloud Six», без перераспределения по артикулу. Один артикул может встречаться под несколькими брендами (бренд берётся из строки, а не из справочника).';
ALTER TABLE wb_metrics_by_cabinet_brand_month_api COMMENT COLUMN brand 'Бренд строки отчёта (brand); пустой бренд и «Неопознанный Товар» — название кабинета, кабинет CloudSix везде «Cloud Six», без перераспределения по артикулу. Один артикул может встречаться под несколькими брендами (бренд берётся из строки, а не из справочника).';
