"""Подключение к control-БД ClickHouse — общеплатформенные таблицы
(projects, users, user_projects), общие для всех проектов и нужные ДО
того, как известно, в какую БД конкретного проекта идти. См.
schema_control.sql и .claude/plans/iridescent-brewing-scroll.md.

Имя control-БД зафиксировано ('control') — это системная константа
платформы, а не то, что меняется между окружениями/клиентами, поэтому
хардкодить его здесь нормально (в отличие от имени БД проекта, которое
всегда приходит из projects.slug).
"""

import os

import clickhouse_connect

CONTROL_DATABASE = "control"


def get_control_client():
    host = os.environ["CLICKHOUSE_HOST"]
    port = int(os.environ.get("CLICKHOUSE_PORT", "8443"))
    user = os.environ.get("CLICKHOUSE_USER", "default")
    password = os.environ["CLICKHOUSE_PASSWORD"]
    secure = os.environ.get("CLICKHOUSE_SECURE", "1") != "0"
    return clickhouse_connect.get_client(
        host=host, port=port, username=user, password=password,
        database=CONTROL_DATABASE, secure=secure,
    )
