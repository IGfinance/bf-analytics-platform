-- Пользователи ClickHouse по проектам (ТЗ 04, блок D). Выполняется под админом (default).
-- Пароли здесь НЕ хранятся: <SHA256_HEX> — sha256 от пароля (python3 -c "import hashlib,sys;print(hashlib.sha256(sys.argv[1].encode()).hexdigest())" 'пароль'),
-- сами пароли лежат только в webapp/.env (сервис) и корневом .env (cron), оба вне git.
-- HOST LOCAL: пользователь принимается только с локальной машины (ClickHouse слушает 127.0.0.1).
--
-- Принцип: каждый потребитель видит ТОЛЬКО свою БД и только нужное действие.
--   app_<проект>  — вебапп и cron проекта: SELECT + INSERT (ReplacingMergeTree, удалений/DDL из кода нет)
--   app_control   — вебапп, служебная БД (проекты/пользователи): только SELECT
--   mb_<БД>       — Metabase: только SELECT на свою БД (по подключению на БД)
-- Новый проект: скопировать блок, заменить имя БД, добавить CLICKHOUSE_USER_<DB>/PASSWORD_<DB> в webapp/.env.

CREATE USER IF NOT EXISTS app_cloudsix IDENTIFIED WITH sha256_hash BY '<SHA256_HEX>' HOST LOCAL;
GRANT SELECT, INSERT ON cloudsix.* TO app_cloudsix;

CREATE USER IF NOT EXISTS app_realt IDENTIFIED WITH sha256_hash BY '<SHA256_HEX>' HOST LOCAL;
GRANT SELECT, INSERT ON realt.* TO app_realt;

CREATE USER IF NOT EXISTS app_control IDENTIFIED WITH sha256_hash BY '<SHA256_HEX>' HOST LOCAL;
GRANT SELECT ON control.* TO app_control;

CREATE USER IF NOT EXISTS mb_cloudsix IDENTIFIED WITH sha256_hash BY '<SHA256_HEX>' HOST LOCAL;
GRANT SELECT ON cloudsix.* TO mb_cloudsix;

CREATE USER IF NOT EXISTS mb_realt IDENTIFIED WITH sha256_hash BY '<SHA256_HEX>' HOST LOCAL;
GRANT SELECT ON realt.* TO mb_realt;

CREATE USER IF NOT EXISTS mb_bottling IDENTIFIED WITH sha256_hash BY '<SHA256_HEX>' HOST LOCAL;
GRANT SELECT ON bottling.* TO mb_bottling;

-- Metabase: долгие запросы не должны жить вечно. Отмену запросов со стороны Metabase (KILL QUERY и
-- SELECT FROM system.processes) НЕ разрешаем сознательно: system.processes показывает запросы ВСЕХ
-- пользователей (проверено 2026-10-02 — виден текст чужого запроса), это утечка между проектами.
-- Вместо этого сервер сам прерывает запрос по времени.
ALTER USER mb_cloudsix SETTINGS max_execution_time = 300;
ALTER USER mb_realt SETTINGS max_execution_time = 300;
ALTER USER mb_bottling SETTINGS max_execution_time = 300;
