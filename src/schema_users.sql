-- Пользователи и их доступ к проектам (переход с единого Basic Auth на
-- многопользовательский логин, см. wiki: 2026-08-31 архитектура — кабинет
-- пользователя, проекты, мультиплощадочность).
--
-- id для users/user_projects, как и для projects (schema_projects.sql),
-- назначается приложением через max(id)+1 — в ClickHouse нет автоинкремента,
-- а нагрузка на запись (единицы сотрудников) не требует более надёжной схемы.

CREATE TABLE IF NOT EXISTS users
(
    id             UInt32,
    email          String,
    password_hash  String,
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

-- Кабинет теперь привязан не только к проекту, но и к площадке (WB, Ozon, …).
-- Существующие строки по умолчанию получают 'wb' — на момент миграции в
-- project_cabinets есть только кабинеты WB.
ALTER TABLE project_cabinets ADD COLUMN IF NOT EXISTS platform String DEFAULT 'wb';

-- 2026-09-05: platform добавлена в ключ дедупликации project_cabinets и
-- brand_cabinets — иначе одинаковый идентификатор кабинета на разных
-- площадках (WB/Ozon) схлопывался бы в одну строку. ClickHouse не позволяет
-- добавить уже заполненную колонку в ORDER BY через MODIFY (BAD_ARGUMENTS,
-- код 36) — обе таблицы пересозданы вручную на проде
-- (CREATE ..._new -> INSERT SELECT -> RENAME -> DROP), с сохранением данных.
-- Итоговое состояние (см. system.tables на проде — источник истины):
--   project_cabinets: колонки без изменений, ORDER BY (cabinet, platform)
--   brand_cabinets:   + колонка platform String DEFAULT 'wb',
--                     ORDER BY (brand_id, cabinet, platform)
-- Для новой БД эти CREATE TABLE в schema_projects.sql нужно поправить так же
-- (там сейчас ещё старые ключи/колонки — правь синхронно, если меняешь схему).

-- Имя/фамилия — показываются в шапке и профиле вместо email. Существующие
-- пользователи получают пустую строку, дозаполняется вручную/через
-- create_user.py --update.
ALTER TABLE users ADD COLUMN IF NOT EXISTS first_name String DEFAULT '';
ALTER TABLE users ADD COLUMN IF NOT EXISTS last_name String DEFAULT '';
