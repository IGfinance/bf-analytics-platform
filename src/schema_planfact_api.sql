-- Операции ПланФакта из API (GET /api/v1/operations) — ОТДЕЛЬНО от
-- planfact_transactions (xlsx): другой ключ (operationId/part_id вместо
-- row_num файла), другие поля (нет № счёта/БИК/ИНН, есть id и даты правок),
-- и xlsx остаётся источником Metabase-моделей, пока API не сверен по
-- статьям/проектам. Одна строка = одна ЧАСТЬ операции (operationParts):
-- статья/проект/контрагент в ПланФакте живут на уровне части, у ~2% операций
-- частей несколько. Операция без частей (перемещение между счетами) — одна
-- строка с part_id = 0.
--
-- Обновление истории: ORDER BY (operation_id, part_id) БЕЗ PARTITION BY —
-- при смене operation_date операция иначе оказалась бы в другой партиции и
-- ReplacingMergeTree не схлопнул бы старую версию. Объём мал (~25 тыс.
-- операций в год). Удалённая в ПланФакте операция → строка-«надгробие» с
-- is_deleted = 1 (см. planfact_api_core.tombstone_missing). Читать через
-- planfact_operations_api_v, не напрямую.
CREATE TABLE IF NOT EXISTS planfact_operations_api
(
    operation_id          UInt64,
    part_id               UInt64,            -- operationPartId, 0 если у операции нет частей
    operation_date        Date,              -- дата платежа (operationDate)
    calculation_date      Nullable(Date),    -- дата начисления (calculationDate части)
    operation_type        LowCardinality(String),   -- Income / Outcome
    is_move               UInt8,             -- перемещение между своими счетами (boundMoveOperationId)
    is_committed          UInt8,
    company_id            UInt64,
    company_title         String,            -- юрлицо счёта
    account_id            UInt64,
    account_title         String,
    currency              LowCardinality(String),
    contragent_id         Nullable(UInt64),
    contragent_title      Nullable(String),
    category_id           Nullable(UInt64),
    category_title        Nullable(String),  -- «Статья» ПланФакта — ключ для planfact_category_mapping
    category_type         Nullable(String),
    activity_type         Nullable(String),
    pf_project_id         Nullable(UInt64),
    pf_project            Nullable(String),  -- «Проекты» — ключ для planfact_brand_map, «Не выбран» = нераспределено
    part_value            Float64,           -- сумма части, всегда ≥ 0
    amount                Float64,           -- со знаком: Income +, Outcome −
    operation_value       Float64,           -- сумма всей операции
    comment               String,
    create_date           Nullable(DateTime),
    modify_date           Nullable(DateTime),
    is_deleted            UInt8 DEFAULT 0,
    loaded_at             DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
ORDER BY (operation_id, part_id);

CREATE OR REPLACE VIEW planfact_operations_api_v AS
SELECT * EXCEPT (is_deleted)
FROM planfact_operations_api FINAL
WHERE is_deleted = 0;
