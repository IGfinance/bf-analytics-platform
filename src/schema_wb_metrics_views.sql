-- VIEW-слой с бизнес-формулами метрик WB — единый источник истины для
-- ЛЮБОГО потребителя: Metabase Model (`src/metabase_queries/wb_metrics_model.sql`,
-- теперь тонкая обёртка над этим VIEW) и будущий AI-бот, если он будет
-- писать ad-hoc SQL к ClickHouse напрямую (см. `.claude/knowledge/architecture-standarts.md`
-- → «Семантический слой для AI-бота»).
--
-- До 2026-09-05 формулы жили ТОЛЬКО внутри Metabase Model (текст в
-- app-БД Metabase) — невидимы для всего, что обращается к ClickHouse в
-- обход Metabase. Перенесены сюда, чтобы бот не реализовывал их заново
-- (риск дрейфа формул — см. инцидент 2026-09-03 в architecture-standarts.md,
-- тот же класс проблемы, только был бы воспроизведён LLM).
--
-- Логика и комментарии по бизнес-правилам перенесены без изменений из
-- `src/metabase_queries/wb_metrics_model.sql` (Model id 49 в проде на
-- 2026-09-05, см. её собственный заголовок про сверку по имени, не id).
-- Одна строка = один (кабинет, месяц), wide-формат.
--
-- Отличия формул от адаптера ig-startup/adapter-wb — см. историю в
-- wb_metrics_model.sql, не дублируем здесь.
--
-- ПРАВКА 2026-09-13 (найдено через reconciliation_rules_wb.yaml, сверка
-- с wb_report_summary — см. её заметки у loyalty_program_cost/
-- loyalty_points_deducted): sum_loyalty_cost и sum_loyalty_points считались
-- простым sum() без вычета "Возврат" — как и sum_loyalty_comp до более
-- ранней правки, это двойной счёт возвратов. Хуже: наивная замена на
-- sumIf(Продажа)-sumIf(Возврат) (по образцу sum_loyalty_comp) молча теряла
-- строки с document_type IS NULL — а в них в некоторых отчётах лежат
-- реальные суммы (до ~4800₽ на отчёт). Формула "всего минус 2×возврат"
-- учитывает Продажу/NULL/Возврат одним выражением и подтверждена точным
-- совпадением (diff≤1e-8) с сводным отчётом на всех 66 парах отчётов.
--
-- `ALTER TABLE ... COMMENT COLUMN` ниже применяется к VIEW (не к обычной
-- таблице) — команды не проверены на реальной версии ClickHouse на проде,
-- накатывайте по одной и проверяйте `SELECT comment FROM system.columns
-- WHERE table = 'wb_metrics_by_cabinet_month'`. Если версия ClickHouse не
-- поддерживает COMMENT COLUMN на VIEW — сам текст пояснений всё равно
-- останется читаемым здесь, в теле ALTER-команд ниже.

CREATE VIEW IF NOT EXISTS wb_metrics_by_cabinet_month AS
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
        coalesce(sum(loyalty_program_cost), 0)
          - 2 * coalesce(sumIf(loyalty_program_cost, document_type = 'Возврат'), 0) AS sum_loyalty_cost,
        coalesce(sum(loyalty_points_deducted), 0)
          - 2 * coalesce(sumIf(loyalty_points_deducted, document_type = 'Возврат'), 0) AS sum_loyalty_points
    FROM wb_reports
    WHERE sale_date IS NOT NULL
    GROUP BY cabinet, month
)
SELECT
    cabinet                                               AS cabinet,
    month                                                  AS month,
    (n_sale - n_ret)                                       AS sales_qty,
    (p_sale - p_ret)                                       AS sales_amount,
    ((t_sale - t_ret) - (p_sale - p_ret))                  AS spp_amount,
    ((ah_sale - ah_ret) - (t_sale - t_ret))                AS wb_commission,
    (ah_sale - ah_ret)                                     AS payable_for_goods,
    (-direct_logistics)                                    AS logistics_direct,
    (-reverse_logistics)                                   AS logistics_reverse,
    sum_transport_comp                                     AS logistics_warehouse_compensation,
    (-sum_fines)                                           AS fines,
    (-sum_correction)                                      AS commission_correction,
    (-sum_storage)                                         AS storage_cost,
    (-sum_acceptance)                                      AS acceptance_cost,
    (-sum_deductions)                                      AS deductions,
    (sum_loyalty_comp - sum_loyalty_cost - sum_loyalty_points) AS wibes_discount,
    (-sum_promo)                                           AS promotion_cost,
    (
      (ah_sale - ah_ret) + (-direct_logistics) + (-reverse_logistics)
      + (-sum_fines) + (-sum_correction) + (-sum_storage) + (-sum_acceptance) + (-sum_deductions)
      + (sum_loyalty_comp - sum_loyalty_cost - sum_loyalty_points) + (-sum_promo)
    )                                                       AS payable_total
FROM base
ORDER BY cabinet, month;

ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN cabinet 'Идентификатор личного кабинета WB (строка), связывается с project_cabinets.cabinet/brand_cabinets.cabinet при platform=''wb''. Один кабинет может быть привязан к нескольким проектам/брендам.';
ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN month 'Начало месяца продажи (по sale_date из wb_reports), время 12:00 — намеренно не 00:00, чтобы Report Timezone в Metabase не сдвигал 1-е число на конец предыдущего месяца.';
ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN sales_qty 'Количество проданных единиц минус возвраты (qty), по payment_reason=продажа/возврат.';
ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN sales_amount 'Продажи в деньгах (wb_realized_amount), продажа минус возврат, только валидные payment_reason из cs_k_types.';
ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN spp_amount 'СПП (скидка постоянного покупателя) = розничная цена с учётом СПП минус фактические продажи.';
ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN wb_commission 'Комиссия Wildberries = розничная цена с СПП минус сумма к перечислению продавцу.';
ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN payable_for_goods 'К перечислению за товар (payable_to_seller), продажа минус возврат.';
ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN logistics_direct 'Логистика "к клиенту" (прямая), определяется по тексту logistics_fines_corrections_type LIKE ''%К клиенту%'', НЕ по qty — на реальных данных qty-подход давал искажение ~300k₽.';
ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN logistics_reverse 'Логистика обратная (не "к клиенту" или тип не указан).';
ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN logistics_warehouse_compensation 'Компенсация логистики/склада (transport_warehouse_compensation) — пока НЕ включена в logistics_* и в payable_total, ждёт отдельной сверки.';
ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN fines 'Штрафы WB (total_fines), знак инвертирован (расход).';
ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN commission_correction 'Доплаты — из wb_commission_correction ("Корректировка Вознаграждения Вайлдберриз"), НЕ из колонки "Доплаты" — такой колонки в реальных выгрузках WB нет.';
ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN storage_cost 'Хранение (storage_cost), знак инвертирован (расход).';
ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN acceptance_cost 'Платная приёмка — из acceptance_operations ("Операции на приемке"), НЕ из колонки "Платная приемка" — такой колонки нет в реальных выгрузках.';
ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN deductions 'Удержание (deductions) за вычетом строк, относящихся к продвижению (см. promotion_cost) — иначе продвижение считалось бы дважды.';
ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN wibes_discount 'Скидка Wibes = loyalty_discount_compensation (продажа минус возврат) минус loyalty_program_cost минус loyalty_points_deducted — оба минус считаются как "всего минус 2×возврат" (сумма по document_type=Продажа/NULL минус сумма по Возврат), см. правку 2026-09-13 в заголовке файла. НЕ из wibes_discount_pct — эта колонка на 100% пустая в реальных выгрузках.';
ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN promotion_cost '"Продвижение WB"/"Продвижение ВБ" объединены в одну метрику — одна и та же статья до/после ребрендинга WB.';
ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN payable_total 'Итог "К перечислению" = payable_for_goods + логистика + штрафы + доплаты + хранение + приёмка + удержание + скидка Wibes + продвижение. НЕ включает logistics_warehouse_compensation (см. её комментарий).';
