-- Metabase: модель "Таблица - Метрики для отчета Wb"
-- Источник для сводной таблицы (Pivot table) — строки=metric, столбцы=month, значение=value
--
-- Порядок строк: числовой префикс "01".."15" (с под-пунктами "07.01"/"07.02"/"07.03") —
-- Metabase сортирует значения pivot по умолчанию по алфавиту/тексту, префикс фиксирует порядок.
--
-- Дата "заякорена" на 12:00 (INTERVAL 12 HOUR), а не 00:00 — иначе Report Timezone
-- в Metabase сдвигает 1-е число месяца на последний день предыдущего (28/29/30/31).
-- См. wiki: knowledge/patterns/Metabase pivot table — сортировка и обход бага часового пояса.md
--
-- Логика расчёта портирована из адаптера ig-startup/adapter-wb (ветка draft,
-- financial-report/aggregator.py::compute_wb_report) — БЕЗ Себестоимости (это отдельная
-- задача, требует загрузки матрицы СС по артикулам/неделям, которой пока нет в ClickHouse).
--
-- Отличия от адаптера (сознательные, проверено на реальных данных wb_reports):
-- 1. Направление логистики (прямая/обратная) — по тексту
--    logistics_fines_corrections_type LIKE '%К клиенту%', а не qty (delivery_qty × cost).
--    В адаптере используется qty-подход, но на реальных данных AcmeShop он даёт искажение
--    ~300k₽ (WB заполняет delivery_qty для строк, которые по смыслу — возврат).
--    См. knowledge/patterns/Metabase pivot table — ... .md
-- 2. «Доплаты» считаем из wb_commission_correction (Корректировка Вознаграждения
--    Вайлдберриз (ВВ)), а не по буквальному поиску колонки "Доплаты". В реальных
--    выгрузках WB такой колонки нет (проверено по wb_unmapped_columns_log — все
--    заголовки замаплены), поэтому в адаптере эта метрика всегда считает 0.
-- 3. «Платная приемка» считаем из acceptance_operations (Операции на приемке) —
--    та же причина: адаптер ищет буквально "Платная приемка"/"Платная приёмка",
--    такой колонки в реальных данных нет, только "Операции на приемке".
-- 4. В «Логистику» дополнительно включена payment_reason = 'Коррекция логистики'
--    (182 строки, ~955₽ за весь период) — раньше учитывался только 'Логистика',
--    эти строки полностью выпадали из отчёта.
-- 5. «Продвижение WB» и «Продвижение ВБ» — объединены в одну метрику: это одна и та же
--    статья (старое/новое название после ребрендинга WB→ВБ), делить смысла нет.
-- 6. «Скидка Wibes» считаем НЕ из wibes_discount_pct («Скидка Wibes, %») — эта колонка
--    100% пустая на всех 334К строк (проверено), в реальных выгрузках WB её не заполняет.
--    Реальные данные лежат в трёх колонках программы лояльности (Wibes = она и есть):
--      loyalty_discount_compensation («Компенсация скидки по программе лояльности») — доход продавца
--      loyalty_program_cost («Стоимость участия в программе лояльности») — расход
--      loyalty_points_deducted («Сумма баллов, удержанных...») — расход
--    skidka_wibes = компенсация − расходы (тот же знаковый паттерн, что у штрафов/удержаний).
-- 7. Добавлена отдельная строка «07.03 Компенсация логистики/склада»
--    (transport_warehouse_compensation, alias "Возмещение издержек по перевозке/по
--    складским операциям с товаром", ~560К₽ за весь период, 191К строк) — раньше нигде
--    не учитывалась. Пока НЕ включена в «Логистику» и в итоговое «15 К перечислению» —
--    ждём сверки с отдельной выгрузкой (report_number → Продажи+СПП..К перечислению),
--    которую пришлёт пользователь, чтобы понять, куда эта сумма реально относится.
--
-- Все строки фильтруются по sale_date IS NOT NULL — как и в адаптере (валидны только
-- строки с заполненной "Датой продажи"). Из-за этого статьи вроде логистики/хранения/
-- штрафов относятся к дате продажи, а не к дате фактической операции — ожидаемое
-- расхождение с еженедельным отчётом WB, за квартал/год сходится (см. checks.py
-- в адаптере, DATE_DISCREPANCY_REASON).

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
        toDateTime(toStartOfMonth(sale_date)) + INTERVAL 12 HOUR AS month,

        -- Кол-во продаж/возвратов — по "Обоснование для оплаты" (payment_reason)
        -- coalesce(...,0) — sumIf/sum над Nullable-колонкой при отсутствии совпадений в месяце
        -- возвращает NULL, а не 0, что иначе протекает в арифметику derived/итоговых метрик
        coalesce(sumIf(qty, lowerUTF8(trim(payment_reason)) = 'продажа'), 0) AS n_sale,
        coalesce(sumIf(qty, lowerUTF8(trim(payment_reason)) = 'возврат'), 0) AS n_ret,

        -- "Товарные" операции: payment_reason из CS_K_TYPES + document_type = Продажа/Возврат
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

        -- Логистика — по тексту типа операции (см. правку №1 выше). payment_reason включает
        -- 'Коррекция логистики' (см. правку №4) — таких строк нет с "К клиенту" в тексте,
        -- поэтому они попадают в обратную логистику.
        coalesce(sumIf(delivery_service_cost,
            payment_reason IN ('Логистика', 'Коррекция логистики') AND logistics_fines_corrections_type LIKE '%К клиенту%'), 0) AS direct_logistics,
        coalesce(sumIf(delivery_service_cost,
            payment_reason IN ('Логистика', 'Коррекция логистики') AND (logistics_fines_corrections_type NOT LIKE '%К клиенту%' OR logistics_fines_corrections_type IS NULL)), 0) AS reverse_logistics,

        -- Компенсация логистики/склада — правка №7, пока отдельно, не в сумме "Логистика"
        coalesce(sum(transport_warehouse_compensation), 0) AS sum_transport_comp,

        coalesce(sum(total_fines), 0) AS sum_fines,
        coalesce(sum(wb_commission_correction), 0) AS sum_correction,          -- "Доплаты", правка №2
        coalesce(sum(storage_cost), 0) AS sum_storage,
        coalesce(sum(acceptance_operations), 0) AS sum_acceptance,              -- "Платная приемка", правка №3
        -- Нормализация как в processor.py::normalize_aq_column — в реальных данных значение
        -- выглядит как "Оказание услуг «WB Продвижение», документ №291909057", суффикс отрезаем
        coalesce(sumIf(deductions,
            trim(REGEXP_REPLACE(REGEXP_REPLACE(logistics_fines_corrections_type, ',\\s*документ\\s*№\\s*\\d+', ''), '\\s+\\d+$', ''))
                NOT IN ('Оказание услуг «WB Продвижение»', 'Оказание услуг «ВБ.Продвижение»')
            OR logistics_fines_corrections_type IS NULL), 0) AS sum_deductions,
        -- Продвижение WB/ВБ — объединены в одну сумму (правка №5)
        coalesce(sumIf(deductions,
            trim(REGEXP_REPLACE(REGEXP_REPLACE(logistics_fines_corrections_type, ',\\s*документ\\s*№\\s*\\d+', ''), '\\s+\\d+$', ''))
                IN ('Оказание услуг «WB Продвижение»', 'Оказание услуг «ВБ.Продвижение»')), 0) AS sum_promo,
        -- Скидка Wibes — из колонок программы лояльности, правка №6
        coalesce(sum(loyalty_discount_compensation), 0) AS sum_loyalty_comp,
        coalesce(sum(loyalty_program_cost), 0) AS sum_loyalty_cost,
        coalesce(sum(loyalty_points_deducted), 0) AS sum_loyalty_points
    FROM wb_reports
    WHERE sale_date IS NOT NULL
    GROUP BY month
),
derived AS (
    SELECT
        month,
        (n_sale - n_ret) AS kol_prodazh,
        (p_sale - p_ret) AS prodazhi,
        ((t_sale - t_ret) - (p_sale - p_ret)) AS spp,
        (ah_sale - ah_ret) AS k_perech_tovar,
        ((ah_sale - ah_ret) - (t_sale - t_ret)) AS komissiya,
        (-direct_logistics) AS pryamaya,
        (-reverse_logistics) AS obratnaya,
        sum_transport_comp AS logistics_compensation,
        (-sum_fines) AS shtrafy,
        (-sum_correction) AS doplaty,
        (-sum_storage) AS khranenie,
        (-sum_acceptance) AS platnaya_priemka,
        (-sum_deductions) AS uderzhanie,
        (sum_loyalty_comp - sum_loyalty_cost - sum_loyalty_points) AS skidka_wibes,
        (-sum_promo) AS promo
    FROM base
)
SELECT * FROM (
    -- toFloat64(...) на каждой ветке — иначе ClickHouse выводит для объединённой
    -- колонки value тип Variant(Float64, Int64) (kol_prodazh из qty — целочисленный,
    -- остальные метрики денежные — Float64), а Metabase не умеет SUM() по Variant
    -- при построении pivot table поверх модели (Code 43, ILLEGAL_TYPE_OF_ARGUMENT).
    SELECT month, '01 Кол-во продаж' AS metric, toFloat64(kol_prodazh) AS value FROM derived
    UNION ALL
    SELECT month, '02 Продажи + СПП' AS metric, toFloat64(prodazhi + spp) AS value FROM derived
    UNION ALL
    SELECT month, '03 Продажи' AS metric, toFloat64(prodazhi) AS value FROM derived
    UNION ALL
    SELECT month, '04 СПП' AS metric, toFloat64(spp) AS value FROM derived
    UNION ALL
    SELECT month, '05 Комиссия ВБ' AS metric, toFloat64(komissiya) AS value FROM derived
    UNION ALL
    SELECT month, '06 К перечислению за товар' AS metric, toFloat64(k_perech_tovar) AS value FROM derived
    UNION ALL
    SELECT month, '07 Логистика' AS metric, toFloat64(pryamaya + obratnaya) AS value FROM derived
    UNION ALL
    SELECT month, '07.01 Логистика прямая' AS metric, toFloat64(pryamaya) AS value FROM derived
    UNION ALL
    SELECT month, '07.02 Логистика обратная' AS metric, toFloat64(obratnaya) AS value FROM derived
    UNION ALL
    SELECT month, '07.03 Компенсация логистики/склада' AS metric, toFloat64(logistics_compensation) AS value FROM derived
    UNION ALL
    SELECT month, '08 Штрафы' AS metric, toFloat64(shtrafy) AS value FROM derived
    UNION ALL
    SELECT month, '09 Доплаты' AS metric, toFloat64(doplaty) AS value FROM derived
    UNION ALL
    SELECT month, '10 Хранение' AS metric, toFloat64(khranenie) AS value FROM derived
    UNION ALL
    SELECT month, '11 Платная приемка' AS metric, toFloat64(platnaya_priemka) AS value FROM derived
    UNION ALL
    SELECT month, '12 Удержание' AS metric, toFloat64(uderzhanie) AS value FROM derived
    UNION ALL
    SELECT month, '13 Скидка Wibes' AS metric, toFloat64(skidka_wibes) AS value FROM derived
    UNION ALL
    SELECT month, '14 Продвижение WB' AS metric, toFloat64(promo) AS value FROM derived
    UNION ALL
    SELECT month, '15 К перечислению' AS metric,
        toFloat64(k_perech_tovar + pryamaya + obratnaya + shtrafy + doplaty
        + khranenie + platnaya_priemka + uderzhanie + skidka_wibes + promo) AS value
    FROM derived
)
ORDER BY month, metric
