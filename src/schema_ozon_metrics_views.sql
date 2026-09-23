-- Помесячные метрики Ozon по кабинету. С 2026-09-23 это ТОНКАЯ АГРЕГАЦИЯ
-- поверх ozon_metrics_by_sku_month (см. schema_ozon_metrics_views_sku.sql) —
-- формулы переехали туда целиком, как это уже сделано у WB. Правьте формулы
-- там, здесь только суммирование по артикулам. Проверено при переводе:
-- все 11 метрик совпали с прежним независимым расчётом побайтово.
-- Комментарии ниже описывают формулы, которые теперь живут в sku-VIEW, и
-- оставлены здесь как история решений по ним.
--
-- VIEW-слой с бизнес-формулами метрик Ozon — единый источник истины,
-- аналог wb_metrics_by_cabinet_month (см. schema_wb_metrics_views.sql —
-- та же мотивация: и Metabase Model, и будущий AI-бот должны видеть одну
-- и ту же формулу, а не пересчитывать её заново).
--
-- Формулы перенесены БЕЗ ИЗМЕНЕНИЙ по существу из уже согласованного и
-- эксплуатируемого скрипта другого проекта:
-- /019-04 FinanceBlackSite/src/scripts/ozon_report.py (compute_ozon()).
-- Это не изобретённая заново логика — код лишь перенесён в SQL.
--
-- ОДНО ОТЛИЧИЕ ОТ ОРИГИНАЛА (проверено на реальных данных CloudSix
-- 2026-09-08): оригинальный скрипт берёт группу услуг "Услуги агентов"
-- для метрики "Последняя миля" — в текущих выгрузках Ozon такой группы
-- нет вообще, есть только "Услуги партнёров" (Ozon переименовал группу).
-- Без этой правки метрика "revenue" НЕ сходится с суммой total_amount по
-- всем строкам — с правкой сходится день-в-день (проверено помесячно за
-- январь-май 2026, расхождение <1e-6 ₽, то есть float-погрешность, не
-- ошибка). Суммируем оба варианта названия — как оригинал уже делает для
-- "Другие услуги"/"Другие услуги и штрафы" (тот же паттерн переименования
-- Ozon, тот же способ защиты от него).
--
-- "Удержание" в оригинале — всегда 0 (не считается из данных, а
-- подставляется в отчёте отдельно, там же где "Займы и факторинг") —
-- сюда не включено вовсе, а не заведено как всегда-0 колонка.
--
-- ВТОРОЕ ОТЛИЧИЕ ОТ ОРИГИНАЛА (сверка с ozon_metrics_by_cabinet_month_api,
-- см. schema_ozon_metrics_views_api.sql, 2026-09-13): группа "Продажи"
-- иногда содержит ОТРИЦАТЕЛЬНЫЕ строки — сторно начисления за доставку
-- покупателю после отмены заказа (в API это отдельная операция
-- OperationAgentStornoDeliveredToCustomer с type='returns'). Оригинал
-- считал их суммой вместе с обычной выручкой (net-эффект на sales_with_spp
-- тот же), но по смыслу это возврат, а не продажа — и в API они размечены
-- именно так. Здесь эти строки исключены из sales_spp/sales/spp и
-- добавлены в corrections, чтобы "Выручка"/"Возвраты" по обоим источникам
-- (API и .xlsx) совпадали не только в сумме, но и в разбивке по бакетам.
-- payable_total (и payable_for_goods) от этой правки не меняется — сумма
-- та же, меняется только то, в какой из двух метрик она сидит.

CREATE VIEW IF NOT EXISTS ozon_metrics_by_cabinet_month AS
SELECT
    cabinet                          AS cabinet,
    month                             AS month,
    toInt32(sum(sales_qty))          AS sales_qty,
    sum(sales_with_spp)              AS sales_with_spp,
    sum(sales_amount)                AS sales_amount,
    sum(spp_amount)                  AS spp_amount,
    sum(commission)                  AS commission,
    sum(returns_corrections)         AS returns_corrections,
    sum(payable_for_goods)           AS payable_for_goods,
    sum(logistics_cost)              AS logistics_cost,
    sum(last_mile_cost)              AS last_mile_cost,
    sum(fines)                       AS fines,
    sum(surcharges)                  AS surcharges,
    sum(storage_cost)                AS storage_cost,
    sum(promotion_cost)              AS promotion_cost,
    sum(other_accruals)              AS other_accruals,
    sum(payable_total)               AS payable_total,
    sum(cogs)                        AS cogs,
    sum(gross_profit)                AS gross_profit,
    sum(cogs_qty_covered)            AS cogs_qty_covered,
    sum(cogs_qty_uncovered)          AS cogs_qty_uncovered
FROM ozon_metrics_by_sku_month
GROUP BY cabinet, month
ORDER BY cabinet, month;

ALTER TABLE ozon_metrics_by_cabinet_month COMMENT COLUMN cabinet 'Идентификатор личного кабинета Ozon (строка), связывается с project_cabinets.cabinet при platform=''ozon''.';
ALTER TABLE ozon_metrics_by_cabinet_month COMMENT COLUMN month 'Начало месяца начисления (по accrual_date из ozon_reports), время 12:00 — намеренно не 00:00, чтобы Report Timezone в Metabase не сдвигал 1-е число на конец предыдущего месяца (тот же приём, что в wb_metrics_by_cabinet_month).';
ALTER TABLE ozon_metrics_by_cabinet_month COMMENT COLUMN sales_qty 'Количество проданных единиц минус возвраты: qty группы "Продажи"/"Выручка" минус |qty| группы "Возвраты"/"Возврат выручки".';
ALTER TABLE ozon_metrics_by_cabinet_month COMMENT COLUMN sales_with_spp 'Выручка + СПП = сумма total_amount по ВСЕМ типам начисления внутри группы "Продажи" (Выручка + Программы партнёров + Баллы за скидки), КРОМЕ отрицательных строк (сторно начисления за доставку после отмены заказа — те уходят в returns_corrections, см. её комментарий) — справочная метрика, не входит в payable_total напрямую (её компоненты sales_amount/spp_amount уже входят по отдельности).';
ALTER TABLE ozon_metrics_by_cabinet_month COMMENT COLUMN sales_amount 'Выручка = группа "Продажи", типы "Выручка" + "Программы партнёров", total_amount >= 0.';
ALTER TABLE ozon_metrics_by_cabinet_month COMMENT COLUMN spp_amount 'СПП = группа "Продажи", тип "Баллы за скидки", total_amount >= 0.';
ALTER TABLE ozon_metrics_by_cabinet_month COMMENT COLUMN commission 'Комиссия Ozon = вся группа "Вознаграждение Ozon" (все типы начисления внутри неё).';
ALTER TABLE ozon_metrics_by_cabinet_month COMMENT COLUMN returns_corrections 'Корректировки, брак, потери и возвраты = вся группа "Возвраты" (все типы) + отрицательные строки группы "Продажи" (сторно начисления за доставку покупателю после отмены заказа — в API это OperationAgentStornoDeliveredToCustomer с type=''returns'', см. schema_ozon_metrics_views_api.sql).';
ALTER TABLE ozon_metrics_by_cabinet_month COMMENT COLUMN payable_for_goods 'К перечислению за товар = sales_amount + spp_amount + commission + returns_corrections.';
ALTER TABLE ozon_metrics_by_cabinet_month COMMENT COLUMN logistics_cost 'Логистика = вся группа "Услуги доставки".';
ALTER TABLE ozon_metrics_by_cabinet_month COMMENT COLUMN last_mile_cost 'Последняя миля = группа "Услуги партнёров" (в старых выгрузках называлась "Услуги агентов" — Ozon переименовал; суммируем оба варианта названия на случай старых данных).';
ALTER TABLE ozon_metrics_by_cabinet_month COMMENT COLUMN fines 'Штрафы = группа "Другие услуги и штрафы" (в старых выгрузках могла называться "Другие услуги" — суммируем оба варианта).';
ALTER TABLE ozon_metrics_by_cabinet_month COMMENT COLUMN surcharges 'Доплаты = вся группа "Компенсации и декомпенсации".';
ALTER TABLE ozon_metrics_by_cabinet_month COMMENT COLUMN storage_cost 'Хранение на складе = вся группа "Услуги FBO".';
ALTER TABLE ozon_metrics_by_cabinet_month COMMENT COLUMN promotion_cost 'Продвижение = вся группа "Продвижение и реклама".';
ALTER TABLE ozon_metrics_by_cabinet_month COMMENT COLUMN other_accruals 'Прочие начисления = вся группа "Прочие начисления".';
ALTER TABLE ozon_metrics_by_cabinet_month COMMENT COLUMN payable_total 'Итог "Выручка к перечислению" = payable_for_goods + logistics_cost + last_mile_cost + fines + surcharges + storage_cost + promotion_cost + other_accruals. НЕ включает "Займы и факторинг" — та метрика не в данных Ozon, подставляется вручную в исходном скрипте ozon_report.py и сюда не перенесена. Проверено: для CloudSix за январь-май 2026 сходится с sum(total_amount) по всем строкам день-в-день (расхождение <1e-6 ₽).';
ALTER TABLE ozon_metrics_by_cabinet_month COMMENT COLUMN cogs 'Себестоимость проданного товара, ₽, знак инвертирован (расход). Сопоставляется поартикульно по неделе начисления из wb_cogs_weekly. Формула — в ozon_metrics_by_sku_month.';
ALTER TABLE ozon_metrics_by_cabinet_month COMMENT COLUMN gross_profit 'Валовая прибыль = payable_total + cogs. Формула — в ozon_metrics_by_sku_month.';
ALTER TABLE ozon_metrics_by_cabinet_month COMMENT COLUMN cogs_qty_covered 'Проданных единиц с известной себестоимостью. Формула — в ozon_metrics_by_sku_month.';
ALTER TABLE ozon_metrics_by_cabinet_month COMMENT COLUMN cogs_qty_uncovered 'Проданных единиц БЕЗ себестоимости (посчитаны по нулю) — на столько занижены cogs/gross_profit. Формула — в ozon_metrics_by_sku_month.';
