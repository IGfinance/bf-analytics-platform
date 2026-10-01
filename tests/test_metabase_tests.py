"""«Тесты» из Metabase на странице «Дашборд» (ТЗ 04, блок B): клиент и рендер."""

import sys
import time
from pathlib import Path

import pytest
import requests

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "webapp"))

import metabase_tests as mt  # noqa: E402


class FakeResp:
    def __init__(self, payload, status=200):
        self.payload, self.status_code = payload, status

    def raise_for_status(self):
        if self.status_code >= 400:
            raise requests.HTTPError(f"{self.status_code}")

    def json(self):
        return self.payload


def card_result(cols, rows):
    return {"status": "completed", "data": {"cols": [{"display_name": c} for c in cols], "rows": rows}}


class FakeSession:
    """Маршрутизирует запросы к Metabase по пути. responses: path-подстрока -> payload|Exception."""

    def __init__(self, responses):
        self.responses, self.calls = responses, []

    def _answer(self, path):
        self.calls.append(path)
        for key, val in self.responses.items():
            if key in path:
                if isinstance(val, Exception):
                    raise val
                return FakeResp(val)
        return FakeResp({}, 404)

    def get(self, url, **kw):
        return self._answer(url)

    def post(self, url, **kw):
        return self._answer(url)


TREE = [{"id": 17, "name": "Тесты", "children": [{"id": 18, "name": "CloudSix"}]}]


def make(cards, results, ttl=300, extra=None):
    items = {"data": [{"id": cid, "model": "card", "name": name, "description": "описание"}
                      for cid, name in cards]}
    responses = {"/api/collection/tree": TREE, "/api/collection/18/items": items}
    responses.update({f"/api/card/{cid}/query": res for cid, res in results.items()})
    responses.update(extra or {})
    sess = FakeSession(responses)
    return mt.MetabaseTestsClient("https://mb.example", "key", ttl, session=sess), sess


def test_all_green_only_when_every_test_passes():
    c, _ = make([(1, "Таблица - CloudSix - Тест А")], {1: card_result(["x"], [])})
    r = c.get_report(["CloudSix"])
    assert r.state == "ok" and r.overall == "ok" and r.counts()["ok"] == 1
    assert r.results[0].name == "Тест А"


def test_rows_mean_error_by_default_and_level_column_sets_warn():
    c, _ = make([(1, "Тест А"), (2, "Тест Б")], {
        1: card_result(["Кабинет"], [["Feel"]]),
        2: card_result(["Колонка", "Уровень"], [["Новая", "warn"]]),
    })
    r = c.get_report(["CloudSix"])
    by = {x.name: x for x in r.results}
    assert by["Тест А"].status == "error"
    assert by["Тест Б"].status == "warn" and by["Тест Б"].columns == ["Колонка"]   # «Уровень» не показываем
    assert r.overall == "error"
    assert [x.name for x in r.results][0] == "Тест А"                                # худшие сверху


def test_error_row_among_warn_rows_makes_error():
    c, _ = make([(1, "Тест")], {1: card_result(["К", "Уровень"], [["a", "warn"], ["b", "error"]])})
    assert c.get_report(["CloudSix"]).results[0].status == "error"


def test_failed_card_is_failed_not_ok_and_does_not_break_others():
    c, _ = make([(1, "Тест А"), (2, "Тест Б")], {
        1: {"status": "failed", "error": "SQL: boom Code: 62 секретная деталь"},
        2: card_result(["x"], []),
    })
    r = c.get_report(["CloudSix"])
    by = {x.name: x for x in r.results}
    assert by["Тест А"].status == "failed" and by["Тест Б"].status == "ok"
    assert "секретная" not in by["Тест А"].message and "Code" not in by["Тест А"].message
    assert r.overall == "failed"


def test_card_http_error_is_failed():
    c, _ = make([(1, "Тест А")], {1: requests.ConnectionError("x")})
    assert c.get_report(["CloudSix"]).results[0].status == "failed"


def test_no_collection_for_project_is_empty_not_green():
    c, _ = make([(1, "Тест")], {1: card_result(["x"], [])})
    r = c.get_report(["Реальт", "realt"])
    assert r.state == "empty" and r.overall == "empty"


def test_collection_without_cards_is_empty():
    c, _ = make([], {})
    assert c.get_report(["CloudSix"]).state == "empty"


def test_metabase_down_without_cache_is_unavailable():
    c, _ = make([], {}, extra={"/api/collection/tree": requests.ConnectionError("down")})
    r = c.get_report(["CloudSix"])
    assert r.state == "unavailable" and r.overall == "unavailable"


def test_metabase_down_with_cache_shows_stale_result():
    c, sess = make([(1, "Тест")], {1: card_result(["x"], [])}, ttl=0)
    first = c.get_report(["CloudSix"])
    sess.responses["/api/collection/tree"] = requests.ConnectionError("down")
    again = c.get_report(["CloudSix"])               # ttl=0 → кэш просрочен, обновление падает
    assert again.stale is True and again.results == first.results and again.state == "ok"


def test_cache_avoids_repeated_calls_and_refresh_bypasses():
    c, sess = make([(1, "Тест")], {1: card_result(["x"], [])})
    c.get_report(["CloudSix"]); n = len(sess.calls)
    c.get_report(["CloudSix"]); assert len(sess.calls) == n
    c.get_report(["CloudSix"], refresh=True); assert len(sess.calls) > n


def test_rows_capped_and_total_reported():
    rows = [[f"r{i}"] for i in range(120)]
    c, _ = make([(1, "Тест")], {1: card_result(["x"], rows)})
    res = c.get_report(["CloudSix"]).results[0]
    assert res.rows_total == 120 and len(res.rows) == mt.MAX_ROWS_SHOWN


def test_no_key_configured_is_unavailable(monkeypatch):
    monkeypatch.setattr(mt, "_client", None)
    monkeypatch.delenv("METABASE_TESTS_API_KEY", raising=False)
    r = mt.get_project_report({"name": "CloudSix", "slug": "cloudsix"})
    assert r.state == "unavailable"


# --------------------------------------------------------------------- страница

def _render(report):
    import app as webapp
    with webapp.app.test_request_context():
        webapp.g.project = {"id": 1, "slug": "cloudsix", "name": "CloudSix"}
        from flask import render_template
        return render_template("dashboard.html", report=report, counts=report.counts(), age_minutes=3,
                               current_project={"slug": "cloudsix", "name": "CloudSix"}, user_projects=[])


def test_page_states_never_green_by_default():
    unavailable = _render(mt.TestsReport("unavailable", message="Проверки временно недоступны."))
    assert "Проверки временно недоступны" in unavailable and "Все проверки пройдены" not in unavailable
    empty = _render(mt.TestsReport("empty", message="Для этого проекта ещё нет проверок."))
    assert "Проверок пока нет" in empty and "Все проверки пройдены" not in empty


def test_page_shows_green_red_and_rows_escaped():
    ok = mt.TestResult(1, "Тест А", "описание", "ok")
    bad = mt.TestResult(2, "Тест <b>Б</b>", "", "error", ["Кабинет"], [["<script>x</script>"]], 1)
    html = _render(mt.TestsReport("ok", [bad, ok], fetched_at=time.time()))
    assert "Есть ошибки" in html and "Пройден" in html and "Ошибка · строк: 1" in html
    assert "<script>x</script>" not in html and "&lt;script&gt;" in html          # автоэкранирование
    green = _render(mt.TestsReport("ok", [ok], fetched_at=time.time()))
    assert "Все проверки пройдены" in green


def test_midnight_datetimes_shown_as_plain_dates_other_values_untouched():
    assert mt._cell("2026-06-01T00:00:00+03:00") == "01.06.2026"
    assert mt._cell("2026-06-01T10:30:00+03:00") == "2026-06-01T10:30:00+03:00"   # со временем — как есть
    assert mt._cell(8971662.53) == "8 971 662.53" and mt._cell(None) == "" and mt._cell(742779887) == "742779887"
