-- Metabase, коллекция «All | Проверки»: по кабинетам и месяцам (карточка 224).
-- Сверка WB API (wb_api_realization) с ручной .xlsx (wb_reports) ОТЧЁТ К ОТЧЁТУ:
-- ключ — номер отчёта (report_number в xlsx = report_id в API), месяц — по концу
-- периода отчёта. Суммы сверяются только по отчётам, которые есть с обеих сторон
-- (допуск 1 ₽, для количества 0,5 шт.). Прежняя помесячная сверка (xlsx по
-- coalesce(order_date, sale_date) против API по rr_date) давала ложные
-- расхождения 10-70 % из-за разного отнесения дат — на 2026-10-04 по отчётам
-- сходятся все 396 общих отчётов по всем 8 статьям.
-- Статусы: ✅ Совпало · ❌ Расхождение · ⚠️ Нет в API (отчёт только в xlsx —
-- 10 отчётов конца декабря 2025, API грузили с 2026-01-01) · ⏳ Ждём xlsx
-- (отчёт только в API — не ошибка).
-- Фильтр «Кабинет» — переменная, как во всех native-карточках проекта.

WITH
x AS (
    SELECT cabinet, toString(report_number) AS rid,
           toDate(max(coalesce(sale_date, order_date))) AS d,
           [toFloat64(sum(payable_to_seller)), toFloat64(sum(wb_realized_amount)), toFloat64(sum(qty)),
            toFloat64(sum(delivery_service_cost)), toFloat64(sum(total_fines)), toFloat64(sum(storage_cost)),
            toFloat64(sum(acceptance_operations)), toFloat64(sum(deductions))] AS v
    FROM wb_reports FINAL
    WHERE 1 = 1
    [[AND cabinet = {{cabinet}}]]
    GROUP BY cabinet, rid
),
a AS (
    SELECT cabinet, toString(report_id) AS rid,
           toDate(max(date_to)) AS d,
           [toFloat64(sum(for_pay)), toFloat64(sum(retail_amount)), toFloat64(sum(quantity)),
            toFloat64(sum(delivery_service)), toFloat64(sum(penalty)), toFloat64(sum(paid_storage)),
            toFloat64(sum(paid_acceptance)), toFloat64(sum(deduction))] AS v
    FROM wb_api_realization FINAL
    WHERE 1 = 1
    [[AND cabinet = {{cabinet}}]]
    GROUP BY cabinet, rid
),
r AS (
    SELECT cabinet, rid, 'x' AS side, d, v FROM x
    UNION ALL
    SELECT cabinet, rid, 'a' AS side, d, v FROM a
),
rep AS (
    SELECT cabinet, rid,
           countIf(side = 'x') > 0 AS has_x,
           countIf(side = 'a') > 0 AS has_a,
           if(countIf(side = 'a') > 0, maxIf(d, side = 'a'), maxIf(d, side = 'x')) AS d,
           anyIf(v, side = 'x') AS xv,
           anyIf(v, side = 'a') AS av
    FROM r
    GROUP BY cabinet, rid
),
chk AS (
    SELECT cabinet, rid, has_x, has_a,
           toStartOfMonth(d) AS month,
           i AS idx,
           arrayElement(['К перечислению продавцу', 'Продажи по розничной цене', 'Количество, шт.',
                         'Логистика', 'Штрафы', 'Платное хранение', 'Платная приёмка', 'Удержания'], i + 1) AS article,
           if(has_x, xv[i + 1], NULL) AS xlsx,
           if(has_a, av[i + 1], NULL) AS api,
           if(i = 2, 0.5, 1.0) AS tol,
           if(has_x AND has_a, if(abs(xv[i + 1] - av[i + 1]) < if(i = 2, 0.5, 1.0), 1, 0), NULL) AS is_ok
    FROM rep
    ARRAY JOIN range(8) AS i
)

SELECT
    cabinet                                                    AS "Кабинет",
    formatDateTime(month, '%Y-%m')                             AS "Месяц",
    uniqExact(rid)                                             AS "Отчётов всего",
    uniqExactIf(rid, has_x AND has_a)                          AS "Отчётов сверено",
    uniqExactIf(rid, has_a AND NOT has_x)                      AS "Только в API, ждём xlsx",
    uniqExactIf(rid, has_x AND NOT has_a)                      AS "Только в xlsx, нет в API",
    countIf(has_x AND has_a)                                   AS "Проверок",
    countIf(is_ok = 1)                                         AS "Совпало",
    countIf(is_ok = 0)                                         AS "Разошлось",
    multiIf(
        countIf(is_ok = 0) > 0,                    '❌ Расхождение',
        countIf(has_x AND NOT has_a) > 0,          '⚠️ Нет в API',
        countIf(has_x AND has_a) > 0,              '✅ Совпало',
        '⏳ Ждём xlsx')                                        AS "Статус"
FROM chk
GROUP BY cabinet, month
ORDER BY month DESC, cabinet
