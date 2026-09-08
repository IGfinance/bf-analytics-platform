-- Metabase: "Модель - Ozon метрики по кабинету и месяцу" (id 62 в проде на
-- 2026-09-08, см. dashboards.finance-black.ru — id меняется, если модель
-- пересоздать заново, сверяйтесь по имени, а не по id).
--
-- Аналог "Модель - WB метрики по кабинету и месяцу" (wb_metrics_model.sql,
-- id 49) — та же роль: тонкая обёртка над ClickHouse VIEW
-- (ozon_metrics_by_cabinet_month, см. ../schema_ozon_metrics_views.sql),
-- формулы считаются только в VIEW, здесь только русские подписи колонок.
-- См. «Семантический слой для AI-бота» в .claude/knowledge/architecture-standarts.md.
--
-- Формулы в VIEW перенесены БЕЗ ИЗМЕНЕНИЙ по существу из уже согласованной
-- и эксплуатируемой логики другого проекта:
-- /019-04 FinanceBlackSite/src/scripts/ozon_report.py (compute_ozon()) —
-- см. подробный разбор различий (переименование группы "Услуги агентов" →
-- "Услуги партнёров") в комментариях самого VIEW.
--
-- Проверено на реальных данных CloudSix (2026-09-08): "Выручка к
-- перечислению" сходится день-в-день с sum(total_amount) по всем строкам
-- ozon_reports для каждого месяца января-июня 2026 (расхождение <1e-6 ₽,
-- то есть float-погрешность, не ошибка формулы).

SELECT
    cabinet             AS "Кабинет",
    month                AS "Месяц",
    sales_qty            AS "Кол-во продаж",
    sales_with_spp        AS "Выручка + СПП",
    sales_amount           AS "Выручка",
    spp_amount               AS "СПП",
    commission                AS "Комиссия",
    returns_corrections         AS "Корректировки, брак, потери и возвраты",
    payable_for_goods            AS "К перечислению за товар",
    logistics_cost                 AS "Логистика",
    last_mile_cost                  AS "Последняя миля",
    fines                            AS "Штрафы",
    surcharges                        AS "Доплаты",
    storage_cost                       AS "Хранение на складе",
    promotion_cost                       AS "Продвижение",
    other_accruals                        AS "Прочие начисления",
    payable_total                          AS "Выручка к перечислению"
FROM ozon_metrics_by_cabinet_month
ORDER BY cabinet, month
