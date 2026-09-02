-- Реестр проектов (клиентов) и группировка кабинетов по проектам/брендам.
-- Термины см. в глоссарии: /019-04 FinanceBlackSite/work/glossary.md
--
-- cabinet остаётся свободной строкой в wb_reports/wb_report_summary —
-- источник истины по списку кабинетов по-прежнему
-- SELECT DISTINCT cabinet FROM wb_reports (docs/tech-spec.md).
-- Эти таблицы только группируют уже существующие кабинеты.

-- Проект — компания/клиент. Один кабинет принадлежит максимум одному
-- проекту: гарантируется тем, что cabinet — ключ дедупа
-- project_cabinets, а не часть составного ключа с project_id.
CREATE TABLE IF NOT EXISTS projects
(
    id                UInt32,
    slug              String,             -- для URL /p/<slug>/...
    name              String,
    telegram_chat_id  Nullable(String),   -- куда слать алерты
    created_at        DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(created_at)
ORDER BY (id);

CREATE TABLE IF NOT EXISTS project_cabinets
(
    cabinet     String,   -- ссылается на значения из wb_reports.cabinet
    project_id  UInt32,
    added_at    DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(added_at)
ORDER BY (cabinet);  -- один кабинет = максимум один проект (1:N)

-- Бренд — бизнес-группировка кабинетов ВНУТРИ проекта. Связь с кабинетом
-- многие-ко-многим (1 бренд может включать несколько кабинетов, 1 кабинет
-- может относиться к нескольким брендам) — в отличие от project_cabinets,
-- здесь нет ограничения на уникальность cabinet.
--
-- НЕ ПУТАТЬ с колонкой wb_reports.brand — это бренд товара (SKU) из
-- самого отчёта WB, построчный атрибут, не связанный с этой сущностью.
CREATE TABLE IF NOT EXISTS brands
(
    id          UInt32,
    project_id  UInt32,
    name        String,
    created_at  DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(created_at)
ORDER BY (id);

CREATE TABLE IF NOT EXISTS brand_cabinets
(
    brand_id  UInt32,
    cabinet   String,
    added_at  DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(added_at)
ORDER BY (brand_id, cabinet);  -- M:N, без уникальности по cabinet
