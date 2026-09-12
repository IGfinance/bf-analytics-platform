-- Реестр включённых источников данных на проект (report.-поддомен) —
-- какие вкладки загрузки видит конкретный проект. НЕ про площадки
-- WB/Ozon (там кабинет = юрлицо на площадке, см. project_cabinets в
-- schema_projects.sql) — здесь источники без концепции кабинета: банк,
-- карты, Клиентикс, Google-Таблицы и т.д. Какие источники УМЕЕТ парсить
-- код, задаётся отдельно константой SUPPORTED_SOURCES в webapp/app.py —
-- эта таблица только про то, что ВКЛЮЧЕНО у конкретного проекта (данные,
-- не код, т.к. набор источников у каждого клиента разный и будет меняться).
CREATE TABLE IF NOT EXISTS project_sources
(
    project_id  UInt32,
    source      String,   -- 'bank_1c' | 'card_pdf' | 'klientiks' | 'gsheets_payroll' | 'gsheets_expenses'
    added_at    DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(added_at)
ORDER BY (project_id, source);
