-- Семантический слой метрик Реальта — формулы считаются здесь один раз,
-- Metabase Model становится тонкой обёрткой (см. architecture-standarts.md,
-- "Семантический слой для AI-бота" и golden example WB
-- wb_metrics_by_cabinet_month в schema_wb_metrics_views.sql).
--
-- TODO(Илья): состав метрик — минимум выручка по услугам (см. человеческое
-- ТЗ), дальше по факту доступных данных из klientiks_operations/
-- realt_payroll/realt_expenses/bank_statements/card_statements. Логику
-- расчёта сверить с черновиком дашбордов (черновик уже у Ильи) перед
-- сдачей — см. Definition of Done в техническом ТЗ.
--
-- COMMENT COLUMN обязателен на бизнес-значимых полях, когда формулы
-- зафиксированы.
CREATE VIEW IF NOT EXISTS realt_metrics_by_month AS
SELECT
    project_id
    -- TODO(Илья): toStartOfMonth(operation_date) AS month, метрики
    -- (выручка по услугам и т.д.), джойны с realt_payroll/realt_expenses/
    -- bank_statements/card_statements по мере необходимости.
FROM klientiks_operations;
