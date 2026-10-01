"""Подключение к ClickHouse с учётными данными ПО ПРОЕКТУ (ТЗ 04, блок D).

Каждая БД проекта (cloudsix, realt, …) и служебная control имеют своего пользователя
ClickHouse с правами только на свою БД. Запрос в БД проекта идёт под ключом этого проекта,
поэтому ошибка/инъекция в одном проекте и утечка одного ключа не открывают данные других.

Ключи берутся из окружения по имени БД:
    CLICKHOUSE_USER_<DB> / CLICKHOUSE_PASSWORD_<DB>      (DB — имя БД в верхнем регистре)
    например CLICKHOUSE_USER_CLOUDSIX, CLICKHOUSE_PASSWORD_CONTROL.
Нет ключей под эту БД — используются общие CLICKHOUSE_USER/CLICKHOUSE_PASSWORD (локальная
разработка, админ-скрипты). CLICKHOUSE_REQUIRE_PROJECT_CREDENTIALS=1 запрещает такой откат:
без ключа проекта подключение не создаётся (режим для веб-сервиса и cron).

Все get_client в src/ и webapp/ вызывают clickhouse_connect ТОЛЬКО через этот модуль
(это проверяет tests/test_ch_connect.py), поэтому логика выбора ключа живёт в одном месте.
"""

from __future__ import annotations

import os
import re

import clickhouse_connect

REQUIRE_FLAG = "CLICKHOUSE_REQUIRE_PROJECT_CREDENTIALS"


def _env_name(prefix: str, database: str) -> str:
    return f"{prefix}_{re.sub(r'[^A-Z0-9]', '_', database.upper())}"


def project_credentials(database: str):
    """(user, password) проекта из окружения либо None, если для этой БД ключей нет."""
    user = os.environ.get(_env_name("CLICKHOUSE_USER", database))
    password = os.environ.get(_env_name("CLICKHOUSE_PASSWORD", database))
    return (user, password) if user and password else None


def get_client(**kwargs):
    """clickhouse_connect.get_client с подменой логина/пароля на ключ проекта.

    database берётся из kwargs, иначе из CLICKHOUSE_DATABASE. Остальные аргументы (host, port,
    secure…) передаются как есть."""
    database = kwargs.get("database") or os.environ.get("CLICKHOUSE_DATABASE") or "default"
    creds = project_credentials(database)
    if creds:
        kwargs["username"], kwargs["password"] = creds
    elif os.environ.get(REQUIRE_FLAG) == "1":
        raise RuntimeError(
            f"Нет учётных данных ClickHouse для БД «{database}» "
            f"({_env_name('CLICKHOUSE_USER', database)}/{_env_name('CLICKHOUSE_PASSWORD', database)}) "
            f"при включённом {REQUIRE_FLAG}.")
    return clickhouse_connect.get_client(**kwargs)
