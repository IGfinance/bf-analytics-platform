-- Metabase: "Визуал - Ozon - Отчет для адаптера (API)" — ДОПОЛНИТЕЛЬНЫЙ отчёт
-- для адаптера по Ozon, посчитанный на данных API. Боевой отчёт на ручной
-- выгрузке (ozon_adapter_report.sql, карточка 44 поверх Модели 62) остаётся
-- как был — этот добавлен рядом, а не вместо.
--
-- ИСТОЧНИК — ozon_metrics_by_cabinet_month_cashflow_api, то есть НОВЫЕ методы
-- Ozon (/v1/finance/cash-flow-statement/list). Выбран из трёх возможных по
-- покрытию, проверенному на данных 2026-09-28:
--   ozon_metrics_by_cabinet_month              .xlsx      7 кабинетов, 01..06
--   ozon_metrics_by_cabinet_month_api          мёртвый метод  1 кабинет, 01..09
--   ozon_metrics_by_cabinet_month_cashflow_api новые методы   8 кабинетов, 01..08
-- Средний вариант построен на /v3/finance/transaction/list, который Ozon
-- отключил — новых данных там не появится, и один кабинет это не отчёт.
--
-- ДВА ИСТОЧНИКА, потому что ни один не даёт всё:
--   строки 01-06 — ozon_realization_by_cabinet_month (метод «Отчёт о
--     реализации»): там есть количество, цена и комиссия отдельными полями;
--   строки 07-15 — ozon_metrics_by_cabinet_month_cashflow_api
--     (cash-flow-statement): там шире покрытие по кабинетам.
-- Cash-flow сам по себе строки 01-06 дать не может: он НЕ разбивает выручку
-- и комиссию, delivery.amount приходит одним числом «выручка минус базовая
-- комиссия» (см. schema_ozon_cashflow_metrics_views.sql).
--
-- JOIN ЛЕВЫЙ, от cash-flow к реализации: кабинетов у cash-flow 8, у
-- реализации 6. Там, где реализации нет, строки 01-06 ПУСТЫЕ, а не нулевые —
-- ноль в отчёте читается как факт, пусто как пробел, и это разные вещи.
-- Пустота сделана ФЛАГОМ has_real, а не настройкой join_use_nulls: по
-- умолчанию ClickHouse подставляет в LEFT JOIN ноль, и CloudNew показывал бы
-- 0 продаж как факт. Настройка join_use_nulls=1 эту задачу решает, но ломает
-- саму вьюху cash-flow («returned Nullable column having not Nullable type»),
-- поэтому флаг.
--
-- Строк 16-17 (себестоимость, валовая прибыль) нет: себестоимость требует
-- количества по артикулу в привязке к справочнику, это отдельная задача.
--
-- СТРОКА «Не разнесено по статьям» — это колонка unmapped самой вьюхи:
-- деньги, которые пришли, но не легли ни в одну статью каталога услуг Ozon.
-- Она вынесена НАРУЖУ намеренно: пока она мала, разбивке можно верить;
-- выросла — значит Ozon добавил код услуги, которого мы не знаем.
--
-- ИЗВЕСТНЫЙ ПРОБЕЛ, унаследованный от источника: last_mile_cost стабильно
-- занижен на 2-4 тыс ₽/мес относительно .xlsx («Упаковка товара партнёрами»,
-- «Временное размещение товара партнерами», FBO-поставочные сборы). Это
-- задокументированный пробел покрытия площадки, см. врезку «три Ozon-метода»
-- в docs/architecture-map.md.
--
-- Фильтр "Кабинет" привязан ЧЕРЕЗ ПЕРЕМЕННУЮ, как и в остальных native SQL
-- карточках проекта: dimension-таргет на native SQL молча перестаёт
-- фильтровать (гочтя из .claude/knowledge/architecture-standarts.md).

SELECT
    c.month                                   AS "Месяц",
    c.cabinet                                 AS "Кабинет",
    'Ozon'                                    AS "Площадка",
    if(r.has_real = 1, toNullable(r.sales_qty), NULL)           AS "01 Кол-во продаж",
    if(r.has_real = 1, toNullable(r.sales_with_spp), NULL)      AS "02 Выручка + СПП",
    if(r.has_real = 1, toNullable(r.sales_amount), NULL)        AS "03 Выручка",
    if(r.has_real = 1, toNullable(r.spp_amount), NULL)          AS "04 СПП",
    if(r.has_real = 1, toNullable(r.commission), NULL)          AS "05 Комиссия",
    if(r.has_real = 1, toNullable(r.returns_corrections), NULL) AS "06 Корректировки, брак, потери и возвраты",
    toFloat64(c.payable_for_goods)            AS "07 К перечислению за товар",
    toFloat64(c.logistics_cost)                 AS "08 Логистика",
    toFloat64(c.last_mile_cost)                 AS "09 Последняя миля",
    toFloat64(c.fines)                          AS "10 Штрафы",
    toFloat64(c.surcharges)                     AS "11 Доплаты",
    toFloat64(c.storage_cost)                   AS "12 Хранение на складе",
    toFloat64(c.promotion_cost)                 AS "13 Продвижение",
    toFloat64(c.other_accruals)                 AS "14 Прочие начисления",
    toFloat64(c.payable_total)                  AS "15 Выручка к перечислению",
    toFloat64(c.unmapped)                       AS "Не разнесено по статьям"
FROM ozon_metrics_by_cabinet_month_cashflow_api AS c
LEFT JOIN (SELECT cabinet, month, 1 AS has_real, sales_qty, sales_with_spp,
                  sales_amount, spp_amount, commission, returns_corrections
           FROM ozon_realization_by_cabinet_month) AS r
       ON r.cabinet = c.cabinet AND r.month = c.month
WHERE 1 = 1
[[AND c.cabinet = {{cabinet}}]]
ORDER BY c.month, c.cabinet

-- ПРОВЕРКА НА ДАННЫХ 2026-09-28, против отчёта на ручной выгрузке
-- (ozon_metrics_by_cabinet_month), общие кабинет-месяцы:
--   январь-май: "07 К перечислению за товар" сходится В НОЛЬ у всех
--     кабинетов (CloudSix, Isonic, Lampa, NoxLab, Torado); логистика,
--     хранение и продвижение тоже ноль или единицы рублей;
--   расходится только "09 Последняя миля" — от 168 ₽ до 88 тыс ₽/мес.
--     Это ровно тот известный пробел покрытия, что описан выше, а не новая
--     проблема;
--   июнь расходится по всем строкам, потому что .xlsx там обрывается на
--     16-м числе, а API отдал месяц целиком — то есть API полнее.
--
-- КАБИНЕТЫ У ИСТОЧНИКОВ РАЗНЫЕ, это видно сразу при открытии:
--   только в API:  CloudNew, HomeMaster
--   только в .xlsx: MaxJansen
--   у X-Tech в API один месяц против шести в .xlsx
-- Поэтому отчёты дополняют друг друга, и ни один не отменяет второй.
--
-- ОСТОРОЖНО с месяцем: у ozon_metrics_by_cabinet_month_cashflow_api колонка
-- month имеет тип Date (без приёма «12:00», который стоит у остальных вьюх
-- проекта). При сравнении с ними нужен toDate() с той стороны, иначе JOIN
-- молча не находит ни строки — так и случилось при первой сверке.
