-- VIEW-слой с бизнес-формулами метрик WB — единый источник истины для
-- ЛЮБОГО потребителя: Metabase Model (`src/metabase_queries/wb_metrics_model.sql`,
-- тонкая обёртка над этим VIEW) и будущий AI-бот, если он будет писать
-- ad-hoc SQL к ClickHouse напрямую (см. `.claude/knowledge/architecture-standarts.md`
-- → «Семантический слой для AI-бота»).
--
-- До 2026-09-05 формулы жили ТОЛЬКО внутри Metabase Model (текст в
-- app-БД Metabase) — невидимы для всего, что обращается к ClickHouse в
-- обход Metabase. Перенесены сюда, чтобы бот не реализовывал их заново
-- (риск дрейфа формул — см. инцидент 2026-09-03 в architecture-standarts.md,
-- тот же класс проблемы, только был бы воспроизведён LLM).
--
-- ПРАВКА 2026-09-14 (найдено при обсуждении "не слишком ли много VIEW"):
-- этот VIEW БОЛЬШЕ НЕ пересчитывает формулы из wb_reports сам — вся
-- бизнес-логика (cs_k_types, разбивка логистики/удержаний/лояльности)
-- теперь ТОЛЬКО в wb_metrics_by_sku_month (см.
-- schema_wb_metrics_views_sku.sql), а этот VIEW — просто GROUP BY cabinet,
-- month, sum(...) поверх него. Раньше формула была продублирована в двух
-- независимых VIEW (этот + sku-версия) — реальный риск дрейфа, уже
-- сработавший один раз: архивная Модель 57 ("WB юнит-экономика по SKU")
-- была построена на СТАРОЙ формуле лояльности и не получила фикс
-- 2026-09-13, потому что жила отдельной копией. Схлопывание корректно
-- математически: все 16 метрик — суммы/разности сумм по строкам
-- wb_reports, а sum() дистрибутивен по дополнительной группировке
-- (сумма по sku, затем сумма по месяцам = сумма сразу по месяцам).
-- Проверено на проде: sum(payable_total) до и после схлопывания совпадает
-- (248 738 549.46 ₽).
--
-- wb_metrics_by_sku_month ДОЛЖЕН существовать в БД до пересоздания этого
-- VIEW (порядок применения schema-файлов: сначала _sku, потом этот).
--
-- ПРАВКА 2026-09-13 (найдено через reconciliation_rules_wb.yaml, сверка
-- с wb_report_summary — см. её заметки у loyalty_program_cost/
-- loyalty_points_deducted в schema_wb_metrics_views_sku.sql): формула
-- "всего минус 2×возврат" для sum_loyalty_cost/sum_loyalty_points —
-- подробности там, не дублируем здесь.
--
-- ПРАВКА 2026-09-14: transport_warehouse_compensation ("Возмещение
-- издержек по перевозке/по складским операциям с товаром") убрана из
-- формулы целиком (не только из этого VIEW, но и из sku_month) — по
-- открытым источникам (напр. https://www.1c-victory.ru/info/integratsiya-s-marketpleysami/vozmeshchenie-izderzhek-po-perevozke-vayldberriz/)
-- это не отдельная выплата продавцу, а компенсация, которую WB платит
-- СВОИМ транспортным подрядчикам за свой счёт, уменьшая тем самым
-- собственную комиссию — сумма уже сидит внутри wb_commission. Показывать
-- её отдельной строкой — задваивать уже учтённые деньги.
--
-- `ALTER TABLE ... COMMENT COLUMN` ниже применяется к VIEW (не к обычной
-- таблице) — команды не проверены на реальной версии ClickHouse на проде,
-- накатывайте по одной и проверяйте `SELECT comment FROM system.columns
-- WHERE table = 'wb_metrics_by_cabinet_month'`. Если версия ClickHouse не
-- поддерживает COMMENT COLUMN на VIEW — сам текст пояснений всё равно
-- останется читаемым здесь, в теле ALTER-команд ниже.

CREATE VIEW IF NOT EXISTS wb_metrics_by_cabinet_month AS
SELECT
    cabinet                          AS cabinet,
    month                             AS month,
    sum(sales_qty)                   AS sales_qty,
    sum(sales_amount)                AS sales_amount,
    sum(spp_amount)                  AS spp_amount,
    sum(wb_commission)               AS wb_commission,
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
FROM wb_metrics_by_sku_month
GROUP BY cabinet, month
ORDER BY cabinet, month;

ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN cabinet 'Идентификатор личного кабинета WB (строка), связывается с project_cabinets.cabinet/brand_cabinets.cabinet при platform=''wb''. Один кабинет может быть привязан к нескольким проектам/брендам.';
ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN month 'Начало месяца продажи (по sale_date из wb_reports), время 12:00 — намеренно не 00:00, чтобы Report Timezone в Metabase не сдвигал 1-е число на конец предыдущего месяца.';
ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN sales_qty 'Количество проданных единиц минус возвраты (qty), по payment_reason=продажа/возврат. Формула — в wb_metrics_by_sku_month, здесь просто сумма по всем артикулам.';
ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN sales_amount 'Продажи в деньгах (wb_realized_amount), продажа минус возврат, только валидные payment_reason из cs_k_types. Формула — в wb_metrics_by_sku_month.';
ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN spp_amount 'СПП (скидка постоянного покупателя) = розничная цена с учётом СПП минус фактические продажи. Формула — в wb_metrics_by_sku_month.';
ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN wb_commission 'Комиссия Wildberries = розничная цена с СПП минус сумма к перечислению продавцу. Формула — в wb_metrics_by_sku_month.';
ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN payable_for_goods 'К перечислению за товар (payable_to_seller), продажа минус возврат. Формула — в wb_metrics_by_sku_month.';
ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN logistics_direct 'Логистика "к клиенту" (прямая). Формула — в wb_metrics_by_sku_month.';
ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN logistics_reverse 'Логистика обратная (не "к клиенту" или тип не указан). Формула — в wb_metrics_by_sku_month.';
ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN fines 'Штрафы WB (total_fines), знак инвертирован (расход). Формула — в wb_metrics_by_sku_month.';
ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN commission_correction 'Доплаты — из wb_commission_correction ("Корректировка Вознаграждения Вайлдберриз"). Формула — в wb_metrics_by_sku_month.';
ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN storage_cost 'Хранение (storage_cost), знак инвертирован (расход). Формула — в wb_metrics_by_sku_month.';
ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN acceptance_cost 'Платная приёмка — из acceptance_operations ("Операции на приемке"). Формула — в wb_metrics_by_sku_month.';
ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN deductions 'Удержание (deductions) за вычетом строк, относящихся к продвижению. Формула — в wb_metrics_by_sku_month.';
ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN wibes_discount 'Скидка Wibes = компенсация минус расходы программы лояльности. Формула — в wb_metrics_by_sku_month.';
ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN promotion_cost '"Продвижение WB"/"Продвижение ВБ" объединены в одну метрику. Формула — в wb_metrics_by_sku_month.';
ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN payable_total 'Итог "К перечислению" = payable_for_goods + логистика + штрафы + доплаты + хранение + приёмка + удержание + скидка Wibes + продвижение. Себестоимость сюда НЕ входит — на этой метрике стоят сверки. Формула — в wb_metrics_by_sku_month.';
ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN cogs 'Себестоимость проданного товара, ₽, знак инвертирован (расход). Сопоставляется поартикульно по неделе операции из wb_cogs_weekly. Формула — в wb_metrics_by_sku_month.';
ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN gross_profit 'Валовая прибыль = payable_total + cogs. Формула — в wb_metrics_by_sku_month.';
ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN cogs_qty_covered 'Проданных единиц с известной себестоимостью. Формула — в wb_metrics_by_sku_month.';
ALTER TABLE wb_metrics_by_cabinet_month COMMENT COLUMN cogs_qty_uncovered 'Проданных единиц БЕЗ себестоимости (посчитаны по нулю) — на столько занижены cogs/gross_profit. Формула — в wb_metrics_by_sku_month.';
