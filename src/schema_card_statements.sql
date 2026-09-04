-- Обороты по личным картам физлиц (справки "Движение средств" из PDF,
-- см. card_statement_pdf.py) — НЕ то же самое, что bank_statements
-- (расчётные счета юрлица из 1С TXT). Разные держатели, нет реквизитов
-- контрагента (ИНН и т.п.), зато есть держатель карты и номер карты
-- операции (у одного счёта может быть несколько карт). Похоже на обороты
-- самовыкупщиков/контрагентов-физлиц — привязка к бренду/схеме пока не
-- сделана, см. knowledge/decisions/2026-09-04 в вики.
CREATE TABLE IF NOT EXISTS card_statements
(
    project_id         UInt32,
    cardholder         Nullable(String),
    source_bank        Nullable(String),
    account_number     Nullable(String),   -- номер лицевого счёта, к которому привязаны карты
    card_number        Nullable(String),   -- последние 4 цифры карты по конкретной операции, если банк их указывает
    operation_date     Nullable(Date),
    processing_date    Nullable(Date),     -- дата списания/обработки, если отличается от даты операции
    amount             Nullable(Float64),  -- всегда положительная
    signed_amount      Nullable(Float64),  -- со знаком: приход +, расход -
    description        Nullable(String),
    row_num            UInt32,             -- позиция операции в исходном файле, для дедупа при перезаливке
    source_file        String,
    loaded_at          DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
PARTITION BY toYYYYMM(coalesce(operation_date, toDate('1970-01-01')))
ORDER BY (project_id, source_file, row_num);
