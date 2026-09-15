-- Выгрузка из Клиентикс (учётная система клиник) — источник данных проекта
-- Реальт. Построчная детализация визитов (клиент/врач/услуга/дата/сумма) —
-- основа для метрик выручки по услугам, когорт и LTV (когорты/LTV строятся
-- по card_number — стабильному ID клиента).
--
-- Формат выгрузки: CSV, кодировка cp1251, разделитель ';', 19 колонок.
-- Структура нестабильна: часть строк приходит с 18 колонками (пропущена
-- пустая колонка в «хвосте»), поэтому парсер (klientiks_core.py) якорит
-- birth_date/gender по содержимому, а не по фиксированной позиции;
-- нераспознанный хвост уходит в extra_columns (паттерн wb_reports/
-- bank_statements). Персональные данные (client_name/client_phone) хранятся
-- по требованию клиента, но НИКОГДА не попадают в логи.
CREATE TABLE IF NOT EXISTS klientiks_operations
(
    project_id             UInt32,
    visit_start            Nullable(DateTime)  COMMENT 'Начало записи — дата и время визита',
    doctor                 Nullable(String)    COMMENT 'Исполнитель (ФИО врача/специалиста)',
    doctor_role            Nullable(String)    COMMENT 'Должность исполнителя (Врач-психиатр, Психолог, ...)',
    service                Nullable(String)    COMMENT 'Название услуги',
    client_name            Nullable(String)    COMMENT 'Имя клиента (PII, не логировать)',
    client_source          Nullable(String)    COMMENT 'Источник клиента (реклама/сайт/...)',
    client_phone           Nullable(String)    COMMENT 'Телефон клиента (PII, не логировать)',
    visit_modified         Nullable(DateTime)  COMMENT 'Дата последнего изменения визита',
    cancel_reason          Nullable(String)    COMMENT 'Причина отмены визита (если отменён)',
    card_number            String              COMMENT 'Номер карты клиента — стабильный ID для когорт/LTV',
    comment                Nullable(String)    COMMENT 'Комментарий к визиту',
    rescheduled            Nullable(String)    COMMENT 'Признак перезаписи визита (сырое значение из выгрузки)',
    amount                 Nullable(Float64)   COMMENT 'Сумма по визиту — основа выручки',
    completed_count        Nullable(UInt32)    COMMENT 'Количество завершённых визитов клиента (кумулятивно)',
    psychologist_category  Nullable(String)    COMMENT 'Категория психолога',
    psychiatrist_category  Nullable(String)    COMMENT 'Категория психиатра',
    birth_date             Nullable(Date32)    COMMENT 'Дата рождения клиента — для метрик по возрасту (Date32: даты до 1970 г.)',
    gender                 Nullable(String)    COMMENT 'Пол клиента (male/female)',
    extra_columns          Map(String, String) COMMENT 'Нераспознанные/лишние поля выгрузки',
    row_num                UInt32              COMMENT 'Позиция строки в исходном файле, для дедупа при перезаливке',
    source_file            String,
    loaded_at              DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
PARTITION BY toYYYYMM(coalesce(toDate(visit_start), toDate('1970-01-01')))
ORDER BY (project_id, source_file, row_num);
