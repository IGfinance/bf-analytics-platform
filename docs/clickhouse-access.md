# Доступы ClickHouse по проектам

Решение ТЗ 04, блок D (2026-10-02). Раньше всё (вебапп, cron, Metabase) ходило под одним
пользователем `default` с полными правами, пароль которого лежал в общем `.env`, читаемом
всеми. Теперь у каждого потребителя свой пользователь с правами только на свою базу.

## Кто под кем ходит

| Потребитель | Пользователь | Права |
|---|---|---|
| Вебапп, база проекта CloudSix / Реальт | `app_cloudsix` / `app_realt` | SELECT, INSERT на `cloudsix.*` / `realt.*` |
| Вебапп, служебная база `control` (проекты, пользователи) | `app_control` | SELECT на `control.*` |
| Cron загрузки CloudSix (WB/Ozon API, ПланФакт) | `app_cloudsix` | как выше |
| Metabase (три подключения) | `mb_cloudsix` / `mb_realt` / `mb_bottling` | SELECT на свою БД |
| Админ: DDL, миграции, ручные загрузки Боттлинга | `default` | полные, только root на сервере |

Что это даёт: ошибка или инъекция в запросе проекта A физически не читает и не пишет базу
проекта B; утечка ключа одного проекта не раскрывает остальные; у Metabase нет прав на запись.

**Чего это НЕ даёт:** ключи всех проектов лежат в `webapp/.env`, который читает сервис. Если
скомпрометирован сам процесс вебаппа (а не отдельный запрос), атакующий получает эти ключи.
Защита от этого — вынос ключей в хранилище секретов (отдельная задача).

## Известные ограничения Metabase под read-only пользователем

- Metabase не может отменять свои долгие запросы (`KILL QUERY` / `system.processes`): эти права
  показывают чужие запросы всем пользователям, поэтому не выданы. Вместо отмены у `mb_*` стоит
  `max_execution_time = 300` — сервер сам обрывает запрос.
- В журнале ClickHouse у `mb_*` будут отказы `Code: 497` на `KILL QUERY` / `system.processes` — ожидаемы.
- Тяжёлые карточки (например «Полный отчет Wb», «Реальт - Юнит-экономика») упираются в тайм-аут nginx
  (60 с, 504) независимо от прав — это скорость запросов, а не доступ.

## Где лежат ключи (прод, `/var/www/report.finance-black.ru`)

- `webapp/.env` (`root:www-data`, 640) — всё, что нужно сервису: `CLICKHOUSE_USER_<БД>` /
  `CLICKHOUSE_PASSWORD_<БД>` для `CLOUDSIX`, `REALT`, `CONTROL`, `CLICKHOUSE_REQUIRE_PROJECT_CREDENTIALS=1`,
  секрет Flask, `METABASE_URL`/`METABASE_TESTS_API_KEY`.
- `.env` (`root:root`, 600) — общий: пароль админа `default`, ключи WB/Ozon/ПланФакта, реквизиты SSH,
  ключ проекта для cron. Сервис (`www-data`) его не читает.

Код выбирает ключ по имени БД в одном месте — `src/ch_connect.py`. Прямой
`clickhouse_connect.get_client` и прямой `dotenv.load_dotenv` в коде запрещены тестами
(`tests/test_ch_connect.py`).

## Как заводить новый проект

1. `src/schema_clickhouse_users.sql` — скопировать блок, заменить БД, задать пароль (sha256).
2. Пароль в `webapp/.env`: `CLICKHOUSE_USER_<DB>=app_<db>`, `CLICKHOUSE_PASSWORD_<DB>=…`.
3. Для Metabase — подключение на БД с пользователем `mb_<db>`.
4. `systemctl restart report-cloudsix.service`.

## DDL и миграции больше не идут через Metabase

Подключения Metabase только на чтение, поэтому прежний приём «DDL через `/api/dataset`» не
работает. DDL выполняется на сервере под `default`: python из venv проекта с корневым `.env`
(`src/ch_connect.get_client(database=…)` без ключа проекта берёт общий логин) либо `clickhouse-client`.

## Откат

Резервные копии файлов и прав перед выкаткой — `/root/backup-deploy-20261002-ch-users*`
(в `perms.txt` исходные права `.env`). Быстрый откат без простоя: вернуть `.env` в 640
`root:www-data`, убрать из `webapp/.env` строки `CLICKHOUSE_REQUIRE_PROJECT_CREDENTIALS` и `CLICKHOUSE_*_<БД>`
и добавить общие `CLICKHOUSE_USER`/`CLICKHOUSE_PASSWORD`; для Metabase — вернуть пользователя `default`
в настройках подключений. Пользователей ClickHouse удалять не нужно.

## Инцидент при выкатке (2026-10-02)

После закрытия корневого `.env` от `www-data` воркеры gunicorn падали с `PermissionError` при
импорте (`wb_summary_core`, `reconcile_wb` читали `.env` без защиты). Простой несколько минут,
устранён возвратом прав; причина исправлена (`src/dotenv_safe.py`, ~37 модулей) и закрыта тестами.
Урок: перед сменой прав на файл конфигурации проверять сервис в отдельном процессе под тем же
пользователем (`runuser -u www-data -- env -i …`) до рестарта.
