-- Банковские выписки в формате 1С (CamlExchange, txt) — сырые проводки по
-- расчётным счетам. Источник богаче ПланФакта (planfact_transactions):
-- прямые реквизиты контрагента (ИНН/счёт/банк/БИК/КПП), но требует ручной
-- выгрузки из банк-клиента по каждому счёту отдельно (в отличие от
-- ПланФакта, который агрегирует все счета сразу, но пока без API-ключа).
-- См. bank_statement_1c.py — парсер вытягивает все поля файла, известные
-- уходят в канонические колонки, редкие/специфичные для типа документа —
-- в extra_columns (тот же паттерн, что extra_columns в wb_reports).
CREATE TABLE IF NOT EXISTS bank_statements
(
    project_id            UInt32,
    account_number        String,
    source_bank           Nullable(String),   -- "Отправитель" из заголовка файла (Т-Банк, Сбербанк, ...)
    doc_type              Nullable(String),   -- "СекцияДокумент", напр. "Платежное поручение"
    doc_number            Nullable(String),
    doc_date              Nullable(Date),      -- "Дата" — дата составления документа
    effective_date        Nullable(Date),      -- ДатаПоступило/ДатаСписано — дата по счёту, зависит от direction
    direction              Enum8('in' = 1, 'out' = 2),
    amount                 Nullable(Float64),   -- всегда положительная
    signed_amount          Nullable(Float64),   -- со знаком: приход +, расход -
    counterparty            Nullable(String),
    counterparty_inn        Nullable(String),
    counterparty_account    Nullable(String),
    counterparty_bank       Nullable(String),
    counterparty_bik        Nullable(String),
    counterparty_kpp        Nullable(String),
    payment_purpose         Nullable(String),
    payment_kind            Nullable(String),   -- "ВидОплаты"
    priority                Nullable(String),   -- "Очередность"
    row_num                 UInt32,             -- позиция документа в исходном файле, для дедупа при перезаливке
    extra_columns           Map(String, String),
    source_file             String,
    loaded_at                DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
PARTITION BY toYYYYMM(coalesce(effective_date, doc_date, toDate('1970-01-01')))
ORDER BY (project_id, source_file, row_num);
