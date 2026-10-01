"""Правки по итогам приёмки ТЗ 04: сообщения об ошибках, изоляция загрузок, троттлинг, доступ."""

import io
import sys
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ROOT / "webapp"))

import app as webapp  # noqa: E402
import auth  # noqa: E402
import metabase_tests as mt  # noqa: E402

PROJECTS = [{"id": 1, "slug": "cloudsix", "name": "CloudSix"}]


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(auth, "find_user_by_id", lambda uid: auth.User(1, "t@example.com", "Иван", "Тестов"))
    monkeypatch.setattr(webapp, "get_user_projects", lambda uid: PROJECTS)
    monkeypatch.setattr(webapp, "get_project_by_slug", lambda slug: PROJECTS[0] if slug == "cloudsix" else None)
    monkeypatch.setattr(webapp, "user_has_project_access", lambda uid, pid: True)
    monkeypatch.setattr(webapp, "get_project_cabinets", lambda pid, db, platform=None: ["Feel"])
    monkeypatch.setattr(webapp, "get_project_platforms", lambda pid, db: ["wb"])
    monkeypatch.setattr(webapp, "get_project_sources", lambda pid, db: [])
    monkeypatch.setattr(webapp, "get_project_cabinet_platforms", lambda pid, db: {"Feel": ["wb"]})
    c = webapp.app.test_client()
    with c.session_transaction() as s:
        s["_user_id"] = "1"
        s["_fresh"] = True
    return c


def post_file(client, url, name="Отчёт №1_1.xlsx"):
    return client.post(url, data={"cabinet": "Feel", "files": (io.BytesIO(b"x"), name), "file": (io.BytesIO(b"x"), name)},
                       content_type="multipart/form-data")


# --- сырой текст исключения не показываем пользователю ---------------------------------------

SECRET = "DB::Exception: Code 60 at 127.0.0.1:8123 password=hunter2 /var/www/report/src/wb_core.py"


@pytest.mark.parametrize("url,attr", [("/p/cloudsix/upload/detail", "ingest_files"),
                                       ("/p/cloudsix/upload/ozon", "ingest_ozon")])
def test_internal_error_text_is_not_shown_to_user(client, monkeypatch, url, attr):
    monkeypatch.setattr(webapp, attr, lambda *a, **k: (_ for _ in ()).throw(RuntimeError(SECRET)))
    r = post_file(client, url)
    body = r.get_data(as_text=True)
    assert r.status_code == 500
    assert "hunter2" not in body and "127.0.0.1" not in body and "/var/www" not in body and "DB::Exception" not in body
    assert webapp.GENERIC_UPLOAD_ERROR in body


def test_summary_route_hides_internal_error_too(client, monkeypatch):
    monkeypatch.setattr(webapp, "ingest_summary", lambda *a, **k: (_ for _ in ()).throw(RuntimeError(SECRET)))
    r = post_file(client, "/p/cloudsix/upload/summary")
    assert r.status_code == 500 and "hunter2" not in r.get_data(as_text=True)


def test_own_russian_validation_message_is_shown(client, monkeypatch):
    msg = "Не удалось найти номер отчёта в имени файла: x.xlsx"
    monkeypatch.setattr(webapp, "ingest_summary", lambda *a, **k: (_ for _ in ()).throw(ValueError(msg)))
    assert msg in post_file(client, "/p/cloudsix/upload/summary").get_data(as_text=True)


# --- у каждого загруженного файла своя папка --------------------------------------------------

def test_same_filename_from_two_requests_never_shares_a_path():
    a, b = webapp.upload_dest("Отчёт №1.xlsx"), webapp.upload_dest("Отчёт №1.xlsx")
    try:
        assert a != b and a.name == b.name == "Отчёт №1.xlsx" and a.parent != b.parent
        a.write_bytes(b"A"); b.write_bytes(b"B")
        assert a.read_bytes() == b"A" and b.read_bytes() == b"B"
    finally:
        webapp.discard_upload(a); webapp.discard_upload(b)
    assert not a.parent.exists() and not b.parent.exists()          # временные папки не копятся


# --- «Обновить» не гоняет тесты чаще раза в 30 с ----------------------------------------------

def test_refresh_is_throttled():
    from test_metabase_tests import make, card_result
    c, sess = make([(1, "Тест")], {1: card_result(["x"], [])})
    c.get_report(["CloudSix"]); n = len(sess.calls)
    for _ in range(5):
        c.get_report(["CloudSix"], refresh=True)
    assert len(sess.calls) == n                                      # кэш моложе 30 с — Metabase не дёргали
    c._cache[next(iter(c._cache))].fetched_at -= mt.REFRESH_MIN_INTERVAL_S + 1
    c.get_report(["CloudSix"], refresh=True)
    assert len(sess.calls) > n                                       # состарился — обновили


# --- чужой проект недоступен -------------------------------------------------------------------

@pytest.mark.parametrize("method,url", [("get", "/p/cloudsix/"), ("get", "/p/cloudsix/upload"),
                                         ("post", "/p/cloudsix/upload/detail"), ("post", "/p/cloudsix/upload/ozon"),
                                         ("post", "/p/cloudsix/upload/summary")])
def test_user_without_project_access_gets_403(client, monkeypatch, method, url):
    monkeypatch.setattr(webapp, "user_has_project_access", lambda uid, pid: False)
    called = []
    monkeypatch.setattr(webapp, "ingest_files", lambda *a, **k: called.append(1))
    r = getattr(client, method)(url)
    assert r.status_code == 403 and not called


def test_unknown_project_is_404(client):
    assert client.get("/p/nonexistent/").status_code == 404


def test_anonymous_user_is_redirected_to_login():
    c = webapp.app.test_client()
    for url in ("/p/cloudsix/", "/p/cloudsix/upload", "/"):
        r = c.get(url)
        assert r.status_code == 302 and "/login" in r.headers["Location"]
