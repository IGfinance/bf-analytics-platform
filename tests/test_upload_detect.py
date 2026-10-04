"""Автоопределение кабинета по файлу: правило решения, определение по данным, поведение загрузки.

Оценка на реальных данных 2026-10-04 (96 детальных WB без самих проверяемых отчётов в «знании», 7 файлов
Ozon): по API-сводке верно 92 и 4 «нет в API», по товарам верно 87 и 9 «не определено», НЕВЕРНЫХ 0.
"""
import datetime as dt
import io
import sys
from pathlib import Path

import openpyxl
import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))
sys.path.insert(0, str(ROOT / "webapp"))

import app as webapp  # noqa: E402
import auth  # noqa: E402
import wb_core  # noqa: E402
import wb_summary_core as summary_core  # noqa: E402
from upload_checks import detect as dt_mod  # noqa: E402
from upload_checks.detect import Detection, decide, detect  # noqa: E402

ALLOWED = ["Feel", "ARB", "CloudSix"]


# ------------------------------------------------------------------ правило решения

def test_decide_picks_clear_winner_only():
    assert decide({"Feel": 9, "ARB": 1}, 10, ALLOWED) == "Feel"
    assert decide({"Feel": 5, "ARB": 5}, 10, ALLOWED) is None             # ничья
    assert decide({"Feel": 3, "ARB": 1}, 10, ALLOWED) is None             # победитель держит меньше половины файла
    assert decide({"Feel": 6, "ARB": 3}, 10, ALLOWED) is None             # преимущество меньше чем втрое
    assert decide({}, 10, ALLOWED) is None and decide({"Feel": 1}, 0, ALLOWED) is None


def test_decide_never_reveals_cabinets_outside_the_project():
    assert decide({"ЧужойКабинет": 10}, 10, ALLOWED) is None
    assert decide({"ЧужойКабинет": 10, "Feel": 2}, 10, ALLOWED) is None   # чужой не «выигрывает» и не мешает считать


# ------------------------------------------------------------------ определение по данным

class FakeKnowledge:
    def __init__(self, reports=None, items=None, skus=None):
        self.reports, self.items, self.skus = reports or {}, items or {}, skus or {}

    def report_cabinets(self, numbers):
        return {n: set(self.reports[n]) for n in numbers if n in self.reports}

    def wb_item_counts(self, items):
        return self.items

    def ozon_sku_counts(self, skus):
        return self.skus


def _xlsx(path: Path, headers, rows, header_row=0):
    wb = openpyxl.Workbook()
    ws = wb.active
    for _ in range(header_row):
        ws.append(["Период: тест"])
    ws.append(list(headers))
    for r in rows:
        ws.append(list(r))
    wb.save(path)
    return path


def test_wb_detail_by_report_number_first(tmp_path):
    f = _xlsx(tmp_path / "Еженедельный детализированный отчет №587583997_4097090.xlsx", ["Код номенклатуры"], [["111"], ["222"]])
    d = detect("wb_detail", f, FakeKnowledge(reports={587583997: ["Feel"]}, items={"ARB": 2}), ALLOWED)
    assert d.cabinet == "Feel" and d.details["by"] == "report_number" and "587583997" in d.reason


def test_wb_detail_falls_back_to_nomenclature(tmp_path):
    f = _xlsx(tmp_path / "Отчёт №5_1.xlsx", ["Код номенклатуры"], [[str(i)] for i in range(10)])
    d = detect("wb_detail", f, FakeKnowledge(items={"ARB": 9}), ALLOWED)
    assert d.cabinet == "ARB" and d.details["by"] == "nomenclature"


def test_wb_detail_report_in_two_cabinets_is_ambiguous(tmp_path):
    f = _xlsx(tmp_path / "Отчёт №5_1.xlsx", ["Код номенклатуры"], [["1"]])
    d = detect("wb_detail", f, FakeKnowledge(reports={5: ["Feel", "ARB"]}), ALLOWED)
    assert d.cabinet is None


def test_ozon_by_sku_and_unknown(tmp_path):
    rows = [["id", "2026-01-01", "Продажи", "Выручка", "A", str(100 + i), "x", 1] for i in range(10)]
    f = _xlsx(tmp_path / "Начисления.xlsx", ["ID начисления", "Дата начисления", "Группа услуг", "Тип начисления", "Артикул", "SKU", "Название товара", "Количество"], rows, header_row=1)
    assert detect("ozon", f, FakeKnowledge(skus={"CloudSix": 9}), ALLOWED).cabinet == "CloudSix"
    assert detect("ozon", f, FakeKnowledge(skus={}), ALLOWED).cabinet is None


def test_summary_by_report_numbers(tmp_path):
    headers = list(summary_core.COLUMN_MAP)
    rows = [[700000000 + i] + [None] * (len(headers) - 1) for i in range(4)]
    f = _xlsx(tmp_path / "Еженедельный отчет.xlsx", headers, rows)
    known = {700000000 + i: ["Feel"] for i in range(4)}
    assert detect("wb_summary", f, FakeKnowledge(reports=known), ALLOWED).cabinet == "Feel"


def test_unreadable_file_never_raises(tmp_path):
    bad = tmp_path / "битый.xlsx"
    bad.write_bytes(b"not an xlsx")
    assert detect("ozon", bad, FakeKnowledge(), ALLOWED).cabinet is None
    assert detect("wb_detail", bad, FakeKnowledge(), ALLOWED).cabinet is None


# ------------------------------------------------------------------ загрузка (маршруты)

PROJECTS = [{"id": 1, "slug": "cloudsix", "name": "CloudSix"}]


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(auth, "find_user_by_id", lambda uid: auth.User(1, "t@example.com", "Иван", "Тестов"))
    monkeypatch.setattr(webapp, "get_user_projects", lambda uid: PROJECTS)
    monkeypatch.setattr(webapp, "get_project_by_slug", lambda slug: PROJECTS[0] if slug == "cloudsix" else None)
    monkeypatch.setattr(webapp, "user_has_project_access", lambda uid, pid: True)
    monkeypatch.setattr(webapp, "get_project_cabinets", lambda pid, db, platform=None: ["Feel", "ARB"])
    monkeypatch.setattr(webapp, "get_project_platforms", lambda pid, db: ["wb", "ozon"])
    monkeypatch.setattr(webapp, "get_project_sources", lambda pid, db: [])
    monkeypatch.setattr(webapp, "get_project_cabinet_platforms", lambda pid, db: {"Feel": ["wb"], "ARB": ["wb"]})
    c = webapp.app.test_client()
    with c.session_transaction() as s:
        s["_user_id"] = "1"
        s["_fresh"] = True
    return c


def _detections(monkeypatch, by_name):
    """by_name: имя файла -> Detection (или Detection(None))."""
    monkeypatch.setattr(webapp, "detect_file_cabinets",
                        lambda door, paths: [(Path(p).name, by_name.get(Path(p).name, Detection(None))) for p in paths])


def _ingest_spy(monkeypatch, attr="ingest_files"):
    calls = []
    monkeypatch.setattr(webapp, attr, lambda files, cabinet, **k: (calls.append(cabinet) or
                        {"files": len(files), "rows": 0, "rows_in_file": 0, "duplicates_skipped": 0, "outcomes": []}))
    return calls


def _post(client, names, cabinet=None, url="/p/cloudsix/upload/detail"):
    data = {"files": [(io.BytesIO(b"x"), n) for n in names]}
    if cabinet:
        data["cabinet"] = cabinet
    return client.post(url, data=data, content_type="multipart/form-data")


def test_no_cabinet_chosen_uses_detected_cabinet(client, monkeypatch):
    _detections(monkeypatch, {"Отчёт №1_1.xlsx": Detection("ARB", "по номеру отчёта № 1")})
    calls = _ingest_spy(monkeypatch)
    r = _post(client, ["Отчёт №1_1.xlsx"])
    assert r.status_code == 200 and calls == ["ARB"]
    assert "Кабинет определён автоматически: «ARB»" in r.get_data(as_text=True)


def test_no_cabinet_and_undetectable_asks_to_choose(client, monkeypatch):
    _detections(monkeypatch, {})
    calls = _ingest_spy(monkeypatch)
    r = _post(client, ["Отчёт №1_1.xlsx"])
    html = r.get_data(as_text=True)
    assert r.status_code == 400 and calls == []
    assert "Не удалось определить кабинет по файлу" in html and "Выберите кабинет вручную" in html


def test_chosen_cabinet_that_contradicts_the_file_is_rejected(client, monkeypatch):
    _detections(monkeypatch, {"Отчёт №1_1.xlsx": Detection("ARB", "по номеру отчёта № 1 — он уже есть в данных кабинета «ARB»")})
    calls = _ingest_spy(monkeypatch)
    r = _post(client, ["Отчёт №1_1.xlsx"], cabinet="Feel")
    html = r.get_data(as_text=True)
    assert r.status_code == 400 and calls == []
    assert "относится к кабинету «ARB»" in html and "выбран «Feel»" in html and "файл не загружен" in html


def test_chosen_cabinet_is_kept_when_file_cannot_be_detected(client, monkeypatch):
    _detections(monkeypatch, {})
    calls = _ingest_spy(monkeypatch)
    assert _post(client, ["Отчёт №1_1.xlsx"], cabinet="Feel").status_code == 200 and calls == ["Feel"]


def test_files_for_different_cabinets_are_not_mixed(client, monkeypatch):
    _detections(monkeypatch, {"Отчёт №1_1.xlsx": Detection("ARB", "x"), "Отчёт №2_1.xlsx": Detection("Feel", "y")})
    calls = _ingest_spy(monkeypatch)
    r = _post(client, ["Отчёт №1_1.xlsx", "Отчёт №2_1.xlsx"])
    assert r.status_code == 400 and calls == [] and "разным кабинетам" in r.get_data(as_text=True)


def test_unknown_cabinet_chosen_is_still_rejected(client, monkeypatch):
    _detections(monkeypatch, {})
    calls = _ingest_spy(monkeypatch)
    assert _post(client, ["Отчёт №1_1.xlsx"], cabinet="Чужой").status_code == 400 and calls == []


def test_uploaded_temp_files_are_removed_after_rejection(client, monkeypatch):
    _detections(monkeypatch, {})
    _ingest_spy(monkeypatch)
    before = {p for p in webapp.UPLOAD_DIR.iterdir()}
    _post(client, ["Отчёт №1_1.xlsx"])
    assert {p for p in webapp.UPLOAD_DIR.iterdir()} == before            # временных папок не осталось


def test_detect_endpoint_returns_cabinet_and_reason(client, monkeypatch):
    _detections(monkeypatch, {"Отчёт №1_1.xlsx": Detection("ARB", "по номеру отчёта № 1")})
    r = client.post("/p/cloudsix/upload/detect/wb_detail", data={"files": (io.BytesIO(b"x"), "Отчёт №1_1.xlsx")},
                    content_type="multipart/form-data")
    assert r.status_code == 200 and r.get_json() == {"cabinet": "ARB", "message": "по номеру отчёта № 1"}


def test_detect_endpoint_handles_unknown_door_wrong_type_and_failure(client, monkeypatch):
    _detections(monkeypatch, {})
    assert client.post("/p/cloudsix/upload/detect/нет_такой").status_code == 404
    r = client.post("/p/cloudsix/upload/detect/ozon_accruals", data={"files": (io.BytesIO(b"x"), "a.csv")},
                    content_type="multipart/form-data")
    assert r.get_json()["cabinet"] is None and ".xlsx" in r.get_json()["message"]
    r = client.post("/p/cloudsix/upload/detect/ozon_accruals", data={"files": (io.BytesIO(b"x"), "a.xlsx")},
                    content_type="multipart/form-data")
    assert r.get_json()["cabinet"] is None


def test_summary_and_ozon_routes_use_detection_too(client, monkeypatch):
    _detections(monkeypatch, {"Начисления.xlsx": Detection("Feel", "по SKU")})
    calls = _ingest_spy(monkeypatch, "ingest_ozon")
    monkeypatch.setattr(webapp, "reject_unknown_cabinet", lambda *a, **k: None)
    r = client.post("/p/cloudsix/upload/ozon", data={"files": (io.BytesIO(b"x"), "Начисления.xlsx")},
                    content_type="multipart/form-data")
    assert r.status_code == 200 and calls == ["Feel"]
