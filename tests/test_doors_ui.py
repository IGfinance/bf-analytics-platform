"""Двери, переключатели и страницы «Загрузка»/«Проекты»/«Профиль» (ТЗ 04, блок C)."""

import re
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ROOT / "webapp"))

import app as webapp  # noqa: E402
import auth  # noqa: E402
import doors  # noqa: E402

PROJECTS = [{"id": 1, "slug": "cloudsix", "name": "CloudSix"}, {"id": 2, "slug": "realt", "name": "Реальт"}]
CABINETS = {"ARB": ["wb"], "CloudSix": ["ozon", "wb"], "Isonic": ["ozon"]}
SOURCES = {1: ["bank_1c", "card_pdf"], 2: ["bank_1c", "card_pdf", "klientiks"]}
PLATFORMS = {1: ["ozon", "wb"], 2: []}


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(auth, "find_user_by_id", lambda uid: auth.User(1, "t@example.com", "Иван", "Тестов"))
    monkeypatch.setattr(webapp, "get_user_projects", lambda uid: PROJECTS)
    monkeypatch.setattr(webapp, "get_project_by_slug", lambda slug: next((p for p in PROJECTS if p["slug"] == slug), None))
    monkeypatch.setattr(webapp, "user_has_project_access", lambda uid, pid: True)
    monkeypatch.setattr(webapp, "get_project_platforms", lambda pid, db: PLATFORMS[pid])
    monkeypatch.setattr(webapp, "get_project_sources", lambda pid, db: SOURCES[pid])
    monkeypatch.setattr(webapp, "get_project_cabinet_platforms", lambda pid, db: CABINETS if pid == 1 else {})
    monkeypatch.setattr(webapp, "get_project_cabinets", lambda pid, db, platform=None: list(CABINETS))
    c = webapp.app.test_client()
    with c.session_transaction() as s:
        s["_user_id"] = "1"
        s["_fresh"] = True
    return c


def page(client, url):
    r = client.get(url)
    assert r.status_code == 200, url
    return r.get_data(as_text=True)


def text(html):
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", html))


# ----------------------------------------------------------------- модель дверей

def test_doors_state_standard_first_and_classification():
    state = doors.doors_state({"wb", "ozon"}, {"bank_1c", "card_pdf", "klientiks"})
    kinds = [d["kind"] for d in state]
    assert kinds == sorted(kinds, key=lambda k: 0 if k == doors.STANDARD else 1)
    by = {d["key"]: d for d in state}
    assert by["wb_detail"]["kind"] == by["ozon_accruals"]["kind"] == by["bank_1c"]["kind"] == doors.STANDARD
    assert by["card_pdf"]["kind"] == by["klientiks"]["kind"] == doors.CUSTOM
    assert all(d["active"] for d in state)


def test_doors_inactive_without_platform_or_source():
    by = {d["key"]: d for d in doors.doors_state({"ozon"}, set())}
    assert by["ozon_accruals"]["active"] and not by["wb_detail"]["active"] and not by["wb_summary"]["active"]
    assert not by["bank_1c"]["active"] and not by["klientiks"]["active"]


def test_unknown_enabled_source_is_custom_and_inactive_not_dropped():
    by = {d["key"]: d for d in doors.doors_state(set(), {"mystery"})}
    assert by["mystery"]["kind"] == doors.CUSTOM and by["mystery"]["active"] is False


# ------------------------------------------------------------------- «Загрузка»

def test_upload_page_has_two_door_sections_with_right_cards(client):
    html = page(client, "/p/cloudsix/upload")
    t = text(html)
    assert t.index("Стандартные двери") < t.index("Индивидуальные двери")
    std, cus = t.split("Индивидуальные двери")
    for title in ("Детальный отчёт WB", "Сводный отчёт + сверка", "Начисления Ozon", "Банковская выписка 1С"):
        assert title in std and title not in cus
    assert "Карточная выписка PDF" in cus and "Карточная выписка PDF" not in std
    assert "Выгрузка Клиентикс" not in t                    # не включена у CloudSix — чужая дверь не показывается


def test_upload_page_project_without_custom_doors_says_so(client, monkeypatch):
    monkeypatch.setitem(SOURCES, 1, ["bank_1c"])
    assert "У проекта пока нет индивидуальных дверей." in text(page(client, "/p/cloudsix/upload"))


def test_cabinet_switcher_lists_cabinets_with_platform_badges_and_meta(client):
    html = page(client, "/p/cloudsix/upload")
    assert 'data-cabinet-select' in html and 'id="upload-cabinet"' in html
    assert re.search(r'data-value="ARB"[^>]*data-meta="wb"', html)
    assert re.search(r'data-value="CloudSix"[^>]*data-meta="ozon,wb"', html)
    assert "Выберите кабинет" in html
    assert "Ozon · WB" in html                                  # бейдж площадок у кабинета на обеих площадках


def test_project_switcher_links_to_same_section_of_other_project(client):
    html = page(client, "/p/cloudsix/upload")
    assert 'data-href="/p/realt/upload"' in html or re.search(r'data-href="[^"]*/p/realt/upload"', html)


def test_cabinet_doors_start_disabled_until_cabinet_chosen(client):
    html = page(client, "/p/cloudsix/upload")
    assert html.count("data-needs-cabinet") >= 3             # WB detail, WB summary, Ozon
    assert "Сначала выберите кабинет." in html
    assert not re.search(r"<select", html)                   # нативных select на странице нет


def test_single_project_switcher_is_disabled(client, monkeypatch):
    monkeypatch.setattr(webapp, "get_user_projects", lambda uid: PROJECTS[:1])
    html = page(client, "/p/cloudsix/upload")
    assert re.search(r'<button[^>]*id="upload-project"[^>]*disabled', html)


def test_no_cabinets_disables_cabinet_switcher(client, monkeypatch):
    monkeypatch.setattr(webapp, "get_project_cabinet_platforms", lambda pid, db: {})
    html = page(client, "/p/cloudsix/upload")
    assert re.search(r'<button[^>]*id="upload-cabinet"[^>]*disabled', html)


def test_project_without_wb_ozon_shows_standard_doors_as_unavailable(client):
    t = text(page(client, "/p/realt/upload"))
    assert "У проекта нет кабинетов WB." in t and "У проекта нет кабинетов Ozon." in t
    assert "Выгрузка Клиентикс" in t                         # у Реальта включена


# --------------------------------------------------------------------- «Проекты»

def test_projects_page_one_row_per_project_with_doors_split(client):
    html = page(client, "/")
    assert html.count('class="project-row"') == 2
    rows = html.split('class="project-row"')[1:]
    cs, realt = rows
    assert "CloudSix" in cs and "Реальт" in realt
    # у CloudSix: стандартные до разделителя, индивидуальные после
    std, sep, cus = cs.partition('class="door-sep"')
    assert sep and "Детальный отчёт WB" in std and "Банковская выписка 1С" in std
    assert "Карточная выписка PDF" in cus and "Выгрузка Клиентикс" not in cus
    # у Реальта WB/Ozon не подключены — серые, но на месте; Клиентикс — индивидуальная
    r_std, _, r_cus = realt.partition('class="door-sep"')
    assert re.search(r"door-chip--off[^>]*>[^<]*Детальный отчёт WB", r_std)
    assert "Выгрузка Клиентикс" in r_cus


# --------------------------------------------------------------- профиль и шапка

def test_profile_has_no_projects_block(client):
    t = text(page(client, "/profile"))
    assert "Доступные проекты" not in t and "t@example.com" in t


def test_header_has_no_notification_bell(client):
    for url in ("/", "/p/cloudsix/", "/p/cloudsix/upload", "/profile"):
        html = page(client, url)
        assert 'aria-label="Алерты"' not in html and "Алерты" not in html


def test_dashboard_uses_styled_switcher(client, monkeypatch):
    import metabase_tests
    monkeypatch.setattr(metabase_tests, "get_project_report",
                        lambda project, refresh=False: metabase_tests.TestsReport("empty", message="нет"))
    html = page(client, "/p/cloudsix/")
    assert 'id="dashboard-project"' in html and not re.search(r"<select", html)
