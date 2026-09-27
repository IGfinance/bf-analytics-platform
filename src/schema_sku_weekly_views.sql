-- VIEW-слой: продажи в ШТУКАХ по артикулу и НЕДЕЛЕ, отдельно для WB и Ozon.
-- Под дашборд «Продажи по артикулам и неделям» (строки — артикулы, столбцы —
-- недели, значение — продажи минус возвраты).
--
-- Зачем отдельные вьюхи, а не разрез в существующих: wb_metrics_by_sku_month и
-- ozon_metrics_by_sku_month агрегируют по МЕСЯЦУ, и добавить туда неделю
-- нельзя — это сменило бы гранулярность всем 20+ метрикам и всем карточкам
-- поверх них. Здесь нужна одна метрика в другом разрезе, поэтому это
-- отдельная узкая вьюха, а не переделка существующих.
--
-- ФОРМУЛА НЕ ВЫДУМАНА ЗАНОВО — взята из канонических вьюх, чтобы «количество
-- продаж» на этом дашборде совпадало с тем же показателем в остальных:
--   WB   (wb_metrics_by_sku_month, sales_qty):
--        sumIf(qty, payment_reason='продажа') - sumIf(qty, payment_reason='возврат'),
--        артикул — supplier_article, дата — sale_date;
--   Ozon (ozon_metrics_by_sku_month, sales_qty):
--        sumIf(qty, service_group='Продажи' AND accrual_type='Выручка')
--      - sumIf(qty, service_group='Возвраты' AND accrual_type='Возврат выручки'),
--        артикул — article, дата — accrual_date.
-- Если правите формулу количества в канонической вьюхе — правьте и здесь,
-- иначе одно и то же число на двух дашбордах разъедется.
--
-- НЕДЕЛЯ: toMonday(дата), то есть неделя помечается датой своего понедельника
-- (понедельник-воскресенье) — так же, как в wb_cogs_weekly, чтобы недели
-- бились с справочником себестоимости.
--
-- ВРЕМЯ 12:00 у недели — намеренно, тот же приём, что у month в канонических
-- вьюхах: при 00:00 Report Timezone в Metabase сдвигает границу назад, и
-- понедельник показывается воскресеньем предыдущей недели.
--
-- КАБИНЕТ обязателен в группировке и должен быть на дашборде фильтром или
-- разрезом. Один и тот же артикул встречается у разных кабинетов, и без
-- кабинета строки молча сложатся — это тот же класс бага, что описан в
-- заголовке wb_metrics_by_sku_month про «артикул это доп. измерение».
--
-- Пустые артикулы помечены 'без артикула', а не NULL — иначе такие строки
-- теряются при GROUP BY/фильтрации.
--
-- Строки, где и продано, и возвращено ноль, отброшены (HAVING): в сырых
-- данных это операционные строки (логистика, хранение, комиссии), у которых
-- qty не заполнен. Они не несут информации о продажах и только раздували бы
-- таблицу. Строка с 0 продаж и 3 возвратами (итог -3) ОСТАЁТСЯ — это факт.

CREATE VIEW IF NOT EXISTS wb_sales_qty_by_sku_week AS
SELECT
    cabinet                                                        AS cabinet,
    toDateTime(toMonday(sale_date)) + INTERVAL 12 HOUR             AS week,
    coalesce(nullIf(trim(supplier_article), ''), 'без артикула')    AS sku,
    anyHeavy(product_name)                                         AS product_name,
    toInt64(coalesce(sumIf(qty, lowerUTF8(trim(payment_reason)) = 'продажа'), 0)) AS qty_sold,
    toInt64(coalesce(sumIf(qty, lowerUTF8(trim(payment_reason)) = 'возврат'), 0)) AS qty_returned,
    toInt64(coalesce(sumIf(qty, lowerUTF8(trim(payment_reason)) = 'продажа'), 0)
          - coalesce(sumIf(qty, lowerUTF8(trim(payment_reason)) = 'возврат'), 0)) AS sales_qty
FROM wb_reports
WHERE sale_date IS NOT NULL
GROUP BY cabinet, week, sku
HAVING qty_sold != 0 OR qty_returned != 0
ORDER BY cabinet, sku, week;

ALTER TABLE wb_sales_qty_by_sku_week COMMENT COLUMN cabinet 'Кабинет WB. ОБЯЗАТЕЛЕН в разрезе или фильтре: один артикул бывает у разных кабинетов, без кабинета строки сложатся молча.';
ALTER TABLE wb_sales_qty_by_sku_week COMMENT COLUMN week 'Понедельник недели продажи (по sale_date), время 12:00 — чтобы Report Timezone в Metabase не сдвинул понедельник на воскресенье. Недели бьются с wb_cogs_weekly.';
ALTER TABLE wb_sales_qty_by_sku_week COMMENT COLUMN sku 'Артикул продавца (supplier_article), пустые — ''без артикула''.';
ALTER TABLE wb_sales_qty_by_sku_week COMMENT COLUMN product_name 'Название товара — самое частое встреченное для этого артикула (anyHeavy).';
ALTER TABLE wb_sales_qty_by_sku_week COMMENT COLUMN qty_sold 'Продано единиц за неделю (payment_reason = ''Продажа''). Счётная колонка, суммируется свободно.';
ALTER TABLE wb_sales_qty_by_sku_week COMMENT COLUMN qty_returned 'Возвращено единиц за неделю (payment_reason = ''Возврат''), положительным числом.';
ALTER TABLE wb_sales_qty_by_sku_week COMMENT COLUMN sales_qty 'Количество продаж за вычетом возвратов = qty_sold - qty_returned. Может быть отрицательным, если в неделю вернули больше, чем купили (возврат приходит позже продажи). Та же формула, что sales_qty в wb_metrics_by_sku_month.';

CREATE VIEW IF NOT EXISTS ozon_sales_qty_by_sku_week AS
SELECT
    cabinet                                                        AS cabinet,
    toDateTime(toMonday(accrual_date)) + INTERVAL 12 HOUR          AS week,
    coalesce(nullIf(trim(article), ''), 'без артикула')             AS sku,
    anyHeavy(product_name)                                         AS product_name,
    toInt64(coalesce(sumIf(qty, service_group = 'Продажи' AND accrual_type = 'Выручка'), 0)) AS qty_sold,
    toInt64(coalesce(sumIf(qty, service_group = 'Возвраты' AND accrual_type = 'Возврат выручки'), 0)) AS qty_returned,
    toInt64(coalesce(sumIf(qty, service_group = 'Продажи' AND accrual_type = 'Выручка'), 0)
          - coalesce(sumIf(qty, service_group = 'Возвраты' AND accrual_type = 'Возврат выручки'), 0)) AS sales_qty
FROM ozon_reports
WHERE accrual_date IS NOT NULL
GROUP BY cabinet, week, sku
HAVING qty_sold != 0 OR qty_returned != 0
ORDER BY cabinet, sku, week;

ALTER TABLE ozon_sales_qty_by_sku_week COMMENT COLUMN cabinet 'Кабинет Ozon. ОБЯЗАТЕЛЕН в разрезе или фильтре — см. тот же комментарий у wb_sales_qty_by_sku_week.';
ALTER TABLE ozon_sales_qty_by_sku_week COMMENT COLUMN week 'Понедельник недели начисления (по accrual_date), время 12:00 — см. комментарий у WB-аналога.';
ALTER TABLE ozon_sales_qty_by_sku_week COMMENT COLUMN sku 'Артикул продавца (article), пустые — ''без артикула''.';
ALTER TABLE ozon_sales_qty_by_sku_week COMMENT COLUMN product_name 'Название товара — самое частое встреченное для этого артикула (anyHeavy).';
ALTER TABLE ozon_sales_qty_by_sku_week COMMENT COLUMN qty_sold 'Продано единиц за неделю (группа ''Продажи'', тип ''Выручка''). Счётная колонка.';
ALTER TABLE ozon_sales_qty_by_sku_week COMMENT COLUMN qty_returned 'Возвращено единиц за неделю (группа ''Возвраты'', тип ''Возврат выручки''), положительным числом.';
ALTER TABLE ozon_sales_qty_by_sku_week COMMENT COLUMN sales_qty 'Количество продаж за вычетом возвратов = qty_sold - qty_returned. Та же формула, что sales_qty в ozon_metrics_by_sku_month.';
