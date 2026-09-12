-- Control-БД: общеплатформенные таблицы, нужные ДО того, как известно, в
-- какую БД проекта идти — кто логинится и к каким проектам у него есть
-- доступ. Применяется к отдельной ClickHouse-базе `control`, не к БД
-- конкретного проекта (см. docs/vision.md и разграничение проектов —
-- .claude/plans/iridescent-brewing-scroll.md).
--
-- Раньше жили вместе с project_cabinets/brands в schema_projects.sql и
-- schema_users.sql внутри одной общей БД — разнесены при переходе на
-- «одна БД = один проект» (2026-09-12). id, как и раньше, назначается
-- приложением через max(id)+1 — в ClickHouse нет автоинкремента, а
-- нагрузка на запись (единицы клиентов/сотрудников) не требует более
-- надёжной схемы.

-- Проект — компания/клиент. slug совпадает с именем ClickHouse-БД
-- проекта (`CREATE DATABASE <slug>`) — один источник правды, отдельной
-- колонки под имя БД не заводим. slug должен быть валидным
-- идентификатором ClickHouse без кавычек (строчные латинские
-- буквы/цифры/`_`).
CREATE TABLE IF NOT EXISTS projects
(
    id                UInt32,
    slug              String,             -- совпадает с именем БД проекта, см. выше
    name              String,
    telegram_chat_id  Nullable(String),   -- куда слать алерты
    created_at        DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(created_at)
ORDER BY (id);

CREATE TABLE IF NOT EXISTS users
(
    id             UInt32,
    email          String,
    password_hash  String,
    first_name     String DEFAULT '',
    last_name      String DEFAULT '',
    created_at     DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(created_at)
ORDER BY (id);

-- Доступ пользователь↔проект, многие-ко-многим: один сотрудник видит
-- несколько проектов, у одного проекта — несколько сотрудников с доступом.
CREATE TABLE IF NOT EXISTS user_projects
(
    user_id     UInt32,
    project_id  UInt32,
    added_at    DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(added_at)
ORDER BY (user_id, project_id);
