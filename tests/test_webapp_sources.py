"""Тесты подключения источников (банк/карты) к webapp.

Проверяют реестр SUPPORTED_SOURCES, сборку карточек источников и площадок
(активные vs disabled/недоступные для проекта — карточки теперь рендерятся
по полному каталогу SOURCE_META/ALL_PLATFORMS всегда, а не только по
включённым в project_sources/project_cabinets) и компиляцию изменённых
шаблонов. get_project_sources замокан — в ClickHouse не ходим.
"""

import os
import sys
from pathlib import Path

import pytest

pytest.importorskip("flask_login")  # webapp-зависимость; скип, если не установлена

os.environ.setdefault("FLASK_SECRET_KEY", "test-secret")

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ROOT / "webapp"))

import app as webapp  # noqa: E402


def test_supported_sources_only_implemented():
    assert webapp.SUPPORTED_SOURCES == {
        "bank_1c", "card_pdf", "klientiks", "gsheets_payroll", "gsheets_expenses",
    }


def test_build_source_cards_active_and_disabled(monkeypatch):
    monkeypatch.setattr(
        webapp, "get_project_sources",
        lambda pid, db: ["bank_1c", "card_pdf", "klientiks", "gsheets_payroll", "unknown_src"],
    )
    with webapp.app.test_request_context():
        cards = webapp.build_source_cards(1, "myproj")

    by_key = {c["key"]: c for c in cards}

    # банк/карты/клиентикс — активные файловые формы (pull=False, есть accept)
    assert by_key["bank_1c"]["supported"] is True
    assert by_key["bank_1c"]["accept"] == ".txt"
    assert by_key["bank_1c"]["pull"] is False
    assert by_key["bank_1c"]["action"] and "/upload/bank" in by_key["bank_1c"]["action"]
    assert by_key["card_pdf"]["accept"] == ".pdf"
    assert "/upload/card" in by_key["card_pdf"]["action"]
    assert by_key["klientiks"]["supported"] is True
    assert by_key["klientiks"]["accept"] == ".csv"
    assert "/upload/klientiks" in by_key["klientiks"]["action"]

    # Google-Таблица «Зарплаты» — активный pull-источник (кнопка-триггер, без файла)
    assert by_key["gsheets_payroll"]["supported"] is True
    assert by_key["gsheets_payroll"]["pull"] is True
    assert by_key["gsheets_payroll"]["accept"] is None
    assert "/upload/gsheets-payroll" in by_key["gsheets_payroll"]["action"]

    # неизвестный код-источник → disabled-заглушка
    assert by_key["unknown_src"]["supported"] is False
    assert by_key["unknown_src"]["action"] is None


def test_gsheets_expenses_is_pull_source(monkeypatch):
    monkeypatch.setattr(webapp, "get_project_sources", lambda pid, db: ["gsheets_expenses"])
    with webapp.app.test_request_context():
        cards = webapp.build_source_cards(1, "myproj")
    card = next(c for c in cards if c["key"] == "gsheets_expenses")
    assert card["supported"] is True
    assert card["pull"] is True
    assert "/upload/gsheets-expenses" in card["action"]


def test_no_sources_gives_all_disabled(monkeypatch):
    """Ни один источник не включён у проекта → карточки всё равно рендерятся
    (весь каталог SOURCE_META), но серые/некликабельные (action=None) — не
    скрываются, чтобы страница загрузки выглядела одинаково у всех проектов."""
    monkeypatch.setattr(webapp, "get_project_sources", lambda pid, db: [])
    with webapp.app.test_request_context():
        cards = webapp.build_source_cards(1, "myproj")
    assert {c["key"] for c in cards} == set(webapp.SOURCE_META.keys())
    assert all(c["enabled"] is False for c in cards)
    assert all(c["action"] is None for c in cards)


def test_build_platform_cards_lists_all_unsupported():
    """Площадки без адаптера — всегда в списке, вне зависимости от
    project_cabinets конкретного проекта (сейчас WB и Ozon уже поддержаны,
    поэтому список пуст — тест проверяет инвариант, а не текущий состав)."""
    cards = webapp.build_platform_cards()
    assert {c["key"] for c in cards} == set(webapp.ALL_PLATFORMS) - webapp.SUPPORTED_PLATFORMS
    assert "wb" not in {c["key"] for c in cards}
    assert "ozon" not in {c["key"] for c in cards}


@pytest.mark.parametrize("template", [
    "upload_form.html",
    "source_result.html",
    "partials/upload_card.html",
    "partials/cabinet_field.html",
])
def test_templates_compile(template):
    # get_template парсит и компилирует шаблон — ловит синтаксические ошибки Jinja
    assert webapp.app.jinja_env.get_template(template) is not None
