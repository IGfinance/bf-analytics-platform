-- Metabase: "Визуал - CloudSix - Отчет для адаптера WB (xlsx)".
--
-- Отчёт для адаптера WB на РУЧНОЙ ВЫГРУЗКЕ .xlsx. Появился 2026-09-28, когда
-- боевой отчёт (карточка 43 поверх Модели 49) переехал на финансовое API:
-- дашборд адаптеров разделили на два — 01 с данными API, 02 с данными .xlsx,
-- чтобы источники можно было сравнить глазами, а не только скриптом сверки.
--
-- Читает wb_metrics_by_cabinet_month НАПРЯМУЮ, а не через Модель: Модель 49
-- теперь указывает на API-вьюху, и заводить вторую Модель ради одной карточки
-- значило бы плодить слой. Формула при этом НЕ дублируется — она живёт во
-- вьюхе, здесь только переименование колонок и нумерация строк, ровно как в
-- wb_adapter_report.sql.
--
-- Колонки и их номера совпадают с API-вариантом один в один, чтобы два отчёта
-- можно было положить рядом и сравнивать построчно.
--
-- ОГРАНИЧЕНИЕ ИСТОЧНИКА: .xlsx грузится руками и отстаёт. На 2026-09-28
-- данные заканчивались 2026-08-16 по CloudSix и 2026-07-12 по
-- Hauser/INOVO/Lampa/Torado — это и было главной причиной расхождений во
-- внешней сверке. Здесь это видно как обрыв последних месяцев.

SELECT
    month                                                  AS "Месяц",
    cabinet                                                 AS "Кабинет",
    'WB'                                                     AS "Площадка",
    toFloat64(sales_qty)                                      AS "01 Кол-во продаж",
    toFloat64(sales_amount + spp_amount)                       AS "02 Продажи + СПП",
    toFloat64(sales_amount)                                     AS "03 Продажи",
    toFloat64(spp_amount)                                        AS "04 СПП",
    toFloat64(wb_commission)                                      AS "05 Комиссия ВБ",
    toFloat64(payable_for_goods)                                   AS "06 К перечислению за товар",
    toFloat64(sales_corrections)                                    AS "06.01 Корректировки продаж",
    toFloat64(logistics_direct + logistics_reverse)                  AS "07 Логистика",
    toFloat64(logistics_direct)                                       AS "07.01 Логистика прямая",
    toFloat64(logistics_reverse)                                       AS "07.02 Логистика обратная",
    toFloat64(fines)                                                    AS "08 Штрафы",
    toFloat64(commission_correction)                                     AS "09 Доплаты",
    toFloat64(storage_cost)                                               AS "10 Хранение",
    toFloat64(acceptance_cost)                                             AS "11 Платная приемка",
    toFloat64(deductions)                                                   AS "12 Удержание",
    toFloat64(wibes_discount)                                                AS "13 Скидка Wibes",
    toFloat64(promotion_cost)                                                 AS "14 Продвижение WB",
    toFloat64(payable_total)                                                   AS "15 К перечислению",
    toFloat64(cogs)                                                             AS "16 Себестоимость",
    toFloat64(gross_profit)                                                      AS "17 Валовая прибыль",
    toFloat64(cogs_qty_covered)                                                   AS "Ед. с себестоимостью",
    toFloat64(cogs_qty_uncovered)                                                  AS "Ед. без себестоимости"
FROM wb_metrics_by_cabinet_month
WHERE 1 = 1
[[AND cabinet = {{cabinet}}]]
ORDER BY month, cabinet
