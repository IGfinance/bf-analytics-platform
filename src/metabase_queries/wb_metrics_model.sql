-- Metabase: "Модель - WB метрики по кабинету и месяцу" (id 49 в проде на
-- 2026-09-03, см. dashboards.finance-black.ru — id меняется, если модель
-- пересоздать заново, сверяйтесь по имени, а не по id).
--
-- Источник истины для отчётных метрик WB (продажи, логистика, штрафы,
-- программа лояльности и т.д.). Остальные Metabase-карточки должны
-- ссылаться на эту модель через конструктор запросов или {{#<id>}} в
-- native SQL, а не копировать формулы заново — см. «Один источник истины
-- для формул» в .claude/knowledge/architecture-standarts.md и инцидент
-- 2026-09-03 в чёрном списке антипаттернов там же.
--
-- Одна строка = один (кабинет, месяц). Это wide-формат (метрика = колонка),
-- в отличие от wb_metrics_by_month.sql (long-формат: строка = метрика),
-- который теперь просто разворачивает эту модель через UNION ALL — см. его
-- заголовок.
--
-- Логика расчёта портирована из адаптера ig-startup/adapter-wb (ветка draft,
-- financial-report/aggregator.py::compute_wb_report) — БЕЗ Себестоимости (это
-- отдельная задача, требует загрузки матрицы СС по артикулам/неделям,
-- которой пока нет в ClickHouse).
--
-- Отличия от адаптера (сознательные, проверено на реальных данных wb_reports):
-- 1. Направление логистики (прямая/обратная) — по тексту
--    logistics_fines_corrections_type LIKE '%К клиенту%', а не qty (delivery_qty × cost).
--    В адаптере используется qty-подход, но на реальных данных AcmeShop он даёт искажение
--    ~300k₽ (WB заполняет delivery_qty для строк, которые по смыслу — возврат).
-- 2. «Доплаты» считаем из wb_commission_correction (Корректировка Вознаграждения
--    Вайлдберриз (ВВ)), а не по буквальному поиску колонки "Доплаты" — такой
--    колонки в реальных выгрузках WB нет.
-- 3. «Платная приемка» считаем из acceptance_operations (Операции на приемке) —
--    та же причина: буквальной колонки "Платная приемка" в данных нет.
-- 4. В «Логистику» дополнительно включена payment_reason = 'Коррекция логистики'
--    (раньше учитывался только 'Логистика', эти строки полностью выпадали).
-- 5. «Продвижение WB» и «Продвижение ВБ» — объединены в одну метрику (одна и та
--    же статья, старое/новое название после ребрендинга).
-- 6. «Скидка Wibes» считаем из трёх колонок программы лояльности
--    (loyalty_discount_compensation − loyalty_program_cost − loyalty_points_deducted),
--    а не из wibes_discount_pct (100% пустая колонка в реальных выгрузках).
--    loyalty_discount_compensation считается через sumIf(document_type),
--    Продажа минус Возврат — правка 2026-09-03, до этого sum() без вычета
--    возвратов задваивал их (тот же баг чинили в reconcile_wb.py 02.09.2026).
-- 7. Отдельная строка «Компенсация логистики/склада»
--    (transport_warehouse_compensation) — пока НЕ включена в «Логистику» и в
--    итоговое «К перечислению итого», ждёт сверки с отдельной выгрузкой.
--
-- Все строки фильтруются по sale_date IS NOT NULL — как и в адаптере (валидны
-- только строки с заполненной "Датой продажи"). Из-за этого статьи вроде
-- логистики/хранения/штрафов относятся к дате продажи, а не к дате фактической
-- операции — ожидаемое расхождение с еженедельным отчётом WB, за квартал/год
-- сходится.

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

        coalesce(sumIf(delivery_service_cost,
            payment_reason IN ('Логистика', 'Коррекция логистики') AND logistics_fines_corrections_type LIKE '%К клиенту%'), 0) AS direct_logistics,
        coalesce(sumIf(delivery_service_cost,
            payment_reason IN ('Логистика', 'Коррекция логистики') AND (logistics_fines_corrections_type NOT LIKE '%К клиенту%' OR logistics_fines_corrections_type IS NULL)), 0) AS reverse_logistics,

        coalesce(sum(transport_warehouse_compensation), 0) AS sum_transport_comp,
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
        coalesce(sum(loyalty_program_cost), 0) AS sum_loyalty_cost,
        coalesce(sum(loyalty_points_deducted), 0) AS sum_loyalty_points
    FROM wb_reports
    WHERE sale_date IS NOT NULL
    GROUP BY cabinet, month
)
SELECT
    cabinet                                               AS "Кабинет",
    month                                                  AS "Месяц",
    (n_sale - n_ret)                                       AS "Кол-во продаж",
    (p_sale - p_ret)                                       AS "Продажи",
    ((t_sale - t_ret) - (p_sale - p_ret))                  AS "СПП",
    ((ah_sale - ah_ret) - (t_sale - t_ret))                AS "Комиссия ВБ",
    (ah_sale - ah_ret)                                     AS "К перечислению за товар",
    (-direct_logistics)                                    AS "Логистика прямая",
    (-reverse_logistics)                                   AS "Логистика обратная",
    sum_transport_comp                                     AS "Компенсация логистики склада",
    (-sum_fines)                                           AS "Штрафы",
    (-sum_correction)                                      AS "Доплаты",
    (-sum_storage)                                         AS "Хранение",
    (-sum_acceptance)                                      AS "Платная приемка",
    (-sum_deductions)                                      AS "Удержание",
    (sum_loyalty_comp - sum_loyalty_cost - sum_loyalty_points) AS "Скидка Wibes",
    (-sum_promo)                                           AS "Продвижение WB",
    (
      (ah_sale - ah_ret) + (-direct_logistics) + (-reverse_logistics)
      + (-sum_fines) + (-sum_correction) + (-sum_storage) + (-sum_acceptance) + (-sum_deductions)
      + (sum_loyalty_comp - sum_loyalty_cost - sum_loyalty_points) + (-sum_promo)
    )                                                       AS "К перечислению итого"
FROM base
ORDER BY cabinet, month
