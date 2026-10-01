"""Ключи ClickHouse по проектам (ТЗ 04, блок D): выбор логина по БД и запрет прямых подключений."""

import re
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

import ch_connect  # noqa: E402

ENV_KEYS = ["CLICKHOUSE_USER", "CLICKHOUSE_PASSWORD", "CLICKHOUSE_DATABASE", ch_connect.REQUIRE_FLAG,
            "CLICKHOUSE_USER_CLOUDSIX", "CLICKHOUSE_PASSWORD_CLOUDSIX", "CLICKHOUSE_USER_REALT",
            "CLICKHOUSE_PASSWORD_REALT", "CLICKHOUSE_USER_CONTROL", "CLICKHOUSE_PASSWORD_CONTROL"]


@pytest.fixture
def seen(monkeypatch):
    for k in ENV_KEYS:
        monkeypatch.delenv(k, raising=False)
    calls = []
    monkeypatch.setattr(ch_connect.clickhouse_connect, "get_client", lambda **kw: calls.append(kw) or object())
    return calls


def test_project_credentials_replace_passed_ones_per_database(seen, monkeypatch):
    monkeypatch.setenv("CLICKHOUSE_USER_CLOUDSIX", "app_cloudsix")
    monkeypatch.setenv("CLICKHOUSE_PASSWORD_CLOUDSIX", "pw-c")
    monkeypatch.setenv("CLICKHOUSE_USER_REALT", "app_realt")
    monkeypatch.setenv("CLICKHOUSE_PASSWORD_REALT", "pw-r")
    ch_connect.get_client(host="h", username="default", password="ADMIN", database="cloudsix")
    ch_connect.get_client(host="h", username="default", password="ADMIN", database="realt")
    assert (seen[0]["username"], seen[0]["password"]) == ("app_cloudsix", "pw-c")
    assert (seen[1]["username"], seen[1]["password"]) == ("app_realt", "pw-r")
    assert seen[0]["host"] == "h" and seen[0]["database"] == "cloudsix"      # прочие аргументы целы


def test_control_database_has_its_own_key(seen, monkeypatch):
    monkeypatch.setenv("CLICKHOUSE_USER_CONTROL", "app_control")
    monkeypatch.setenv("CLICKHOUSE_PASSWORD_CONTROL", "pw")
    ch_connect.get_client(host="h", username="default", password="ADMIN", database="control")
    assert seen[0]["username"] == "app_control"


def test_database_taken_from_env_when_not_passed(seen, monkeypatch):
    monkeypatch.setenv("CLICKHOUSE_DATABASE", "cloudsix")
    monkeypatch.setenv("CLICKHOUSE_USER_CLOUDSIX", "app_cloudsix")
    monkeypatch.setenv("CLICKHOUSE_PASSWORD_CLOUDSIX", "pw-c")
    ch_connect.get_client(host="h", username="default", password="ADMIN")
    assert seen[0]["username"] == "app_cloudsix"


def test_no_project_key_falls_back_to_passed_credentials(seen):
    ch_connect.get_client(host="h", username="default", password="ADMIN", database="bottling")
    assert (seen[0]["username"], seen[0]["password"]) == ("default", "ADMIN")


def test_half_configured_key_is_not_used(seen, monkeypatch):
    monkeypatch.setenv("CLICKHOUSE_USER_CLOUDSIX", "app_cloudsix")            # пароля нет
    ch_connect.get_client(host="h", username="default", password="ADMIN", database="cloudsix")
    assert seen[0]["username"] == "default"


def test_require_flag_forbids_fallback_to_shared_credentials(seen, monkeypatch):
    monkeypatch.setenv(ch_connect.REQUIRE_FLAG, "1")
    with pytest.raises(RuntimeError) as e:
        ch_connect.get_client(host="h", username="default", password="ADMIN", database="realt")
    assert "CLICKHOUSE_USER_REALT" in str(e.value) and "ADMIN" not in str(e.value)   # пароль в ошибку не попадает
    assert seen == []                                                                  # подключение не создавалось


def test_service_without_shared_password_still_builds_client_via_module_get_client(seen, monkeypatch):
    """Сервис без общего CLICKHOUSE_PASSWORD (прод после разделения .env) не падает с KeyError."""
    import wb_core
    monkeypatch.setenv("CLICKHOUSE_HOST", "127.0.0.1")
    monkeypatch.setenv("CLICKHOUSE_USER_CLOUDSIX", "app_cloudsix")
    monkeypatch.setenv("CLICKHOUSE_PASSWORD_CLOUDSIX", "pw-c")
    monkeypatch.setenv(ch_connect.REQUIRE_FLAG, "1")
    wb_core.get_client(database="cloudsix")
    assert seen[0]["username"] == "app_cloudsix"


def test_no_module_connects_to_clickhouse_directly():
    """Единственное место прямого clickhouse_connect.get_client — ch_connect.py: иначе новый модуль
    молча обойдёт ключи проектов и пойдёт под общим логином."""
    offenders = []
    for folder in ("src", "webapp", "scripts"):
        for path in (ROOT / folder).rglob("*.py"):
            if path.name == "ch_connect.py":
                continue
            if re.search(r"clickhouse_connect\.get_(async_)?client\(", path.read_text(encoding="utf-8")):
                offenders.append(str(path.relative_to(ROOT)))
    assert offenders == []


# ------------------------------------------------- .env, недоступный сервису (инцидент 2026-10-02)

def test_dotenv_safe_survives_unreadable_env_file(tmp_path):
    import os
    import dotenv_safe
    f = tmp_path / ".env"
    f.write_text("X_TEST_VAR=1\n")
    f.chmod(0o000)
    try:
        if os.access(f, os.R_OK):
            pytest.skip("файл читается (root) — нечем проверять отказ в доступе")
        assert dotenv_safe.load_dotenv(f) is False                 # не бросает PermissionError
    finally:
        f.chmod(0o600)


def test_no_module_calls_python_dotenv_load_dotenv_directly():
    """Прямой dotenv.load_dotenv на недоступном .env роняет воркеры сервиса при импорте."""
    offenders = []
    for folder in ("src", "webapp"):
        for path in (ROOT / folder).rglob("*.py"):
            if path.name == "dotenv_safe.py":
                continue
            if re.search(r"from dotenv import .*load_dotenv|dotenv\.load_dotenv\(", path.read_text(encoding="utf-8")):
                offenders.append(str(path.relative_to(ROOT)))
    assert offenders == []


def test_webapp_imports_with_unreadable_root_env(monkeypatch, tmp_path):
    """Приложение импортируется, даже если загрузка корневого .env бросает PermissionError."""
    import dotenv
    real = dotenv.load_dotenv

    def deny(path=None, *a, **kw):
        if str(path).endswith("/.env") and "webapp" not in str(path):
            raise PermissionError(13, "Permission denied", str(path))
        return real(path, *a, **kw)

    monkeypatch.setattr(dotenv, "load_dotenv", deny)
    for name in ("app", "wb_summary_core", "reconcile_wb", "wb_core"):
        sys.modules.pop(name, None)
    sys.path.insert(0, str(ROOT / "webapp"))
    import importlib
    importlib.import_module("app")
