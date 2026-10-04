"""Загрузка «Еженедельного сводного отчёта» WB: чужой файл отклоняется ДО записи.

Баг 2026-10-04: у этой двери не было проверок — чужой xlsx разбирался в тысячи строк с пустыми
полями (23 592 строки из банковской выписки), а разбор лишь писал в лог «колонка не найдена».
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

import wb_core  # noqa: E402
import wb_summary_core as core  # noqa: E402
from upload_checks import summary as usummary  # noqa: E402
from upload_checks.core import UploadRejected, ERROR, WARN  # noqa: E402


class FakeClient:
    def __init__(self):
        self.inserts = []

    def insert(self, table, data, column_names=None, **k):
        self.inserts.append((table, len(data)))


def _xlsx(path: Path, headers, rows):
    wb = openpyxl.Workbook()
    ws = wb.active
    ws.append(list(headers))
    for r in rows:
        ws.append(list(r))
    wb.save(path)
    return path


def _summary_row(i):
    row = []
    for header, (canon, t) in core.COLUMN_MAP.items():
        if canon == "report_number":
            row.append(700000000 + i)
        elif t == "Float64":
            row.append(100.5 * i)
        elif t == "Date":
            row.append(dt.date(2026, 9, i))
        else:
            row.append("RUB" if canon == "currency" else f"{canon}-{i}")
    return row


@pytest.fixture
def fake(monkeypatch):
    f = FakeClient()
    monkeypatch.setattr(core, "get_client", lambda database=None: f)
    return f


def _foreign(tmp_path):
    return _xlsx(tmp_path / "Выписка.xlsx", ["Дата", "Контрагент", "Сумма", "Назначение"],
                 [(dt.date(2026, 6, i), "ООО Тест", 1000.0 * i, "оплата") for i in range(1, 6)])


def test_foreign_file_is_rejected_before_any_write(tmp_path, fake):
    with pytest.raises(UploadRejected) as e:
        usummary.ingest([_foreign(tmp_path)], "CloudSix", log=lambda *a: None, database="cloudsix", user_id=1)
    msgs = " ".join(r.message for r in e.value.results if r.severity == ERROR)
    assert "не похож на «Еженедельный сводный отчёт»" in msgs and "Файл не загружен" in msgs
    # в wb_report_summary не записано ничего; допустим только журнал проверок
    assert [t for t, _ in fake.inserts if t == "wb_report_summary"] == []


def test_detail_report_in_summary_door_gets_a_hint(tmp_path, fake):
    alias_to_canonical, _ = wb_core.load_mapping()
    headers = list(alias_to_canonical)[:30]            # заголовки ДЕТАЛЬНОГО отчёта
    path = _xlsx(tmp_path / "Детальный.xlsx", headers, [[1] * len(headers)])
    with pytest.raises(UploadRejected) as e:
        usummary.ingest([path], "CloudSix", log=lambda *a: None, database="cloudsix")
    assert "детальный отчёт" in " ".join(r.message for r in e.value.results)


def test_valid_summary_is_accepted_and_written(tmp_path, fake):
    path = _xlsx(tmp_path / "Еженедельный отчет.xlsx", list(core.COLUMN_MAP), [_summary_row(i) for i in range(1, 4)])
    res = usummary.ingest([path], "CloudSix", log=lambda *a: None, database="cloudsix", user_id=1)
    assert res["rows"] == 3
    assert ("wb_report_summary", 3) in fake.inserts


def test_renamed_money_column_is_an_error(tmp_path, fake):
    headers = [h if h != "Итого к оплате" else "Итого к оплате (новое имя)" for h in core.COLUMN_MAP]
    path = _xlsx(tmp_path / "s.xlsx", headers, [_summary_row(1)])
    with pytest.raises(UploadRejected):
        usummary.ingest([path], "CloudSix", log=lambda *a: None, database="cloudsix")


def test_total_row_without_number_is_skipped_with_warning(tmp_path, fake):
    rows = [_summary_row(1), _summary_row(2), [None] * len(core.COLUMN_MAP)]
    rows[2][0] = "Итого"                      # строка итогов: «№ отчета» — текст, остальное пусто
    path = _xlsx(tmp_path / "s.xlsx", list(core.COLUMN_MAP), rows)
    assert any(r.severity == WARN and r.name == "rows_without_report_number" for r in usummary.check_file(path))
    res = usummary.ingest([path], "CloudSix", log=lambda *a: None, database="cloudsix")
    assert res["rows"] == 2 and ("wb_report_summary", 2) in fake.inserts


def test_core_refuses_rows_without_report_number(tmp_path, fake):
    """Страховка для CLI/обходных путей: пустышки в UInt64-колонку не отправляем."""
    with pytest.raises(ValueError, match="нет ни одной строки с номером отчёта"):
        core.ingest_files([_foreign(tmp_path)], "CloudSix", log=lambda *a: None, database="cloudsix")
    assert [t for t, _ in fake.inserts if t == "wb_report_summary"] == []


# --- сквозной: то, что видит пользователь на странице ---------------------------------------------

import app as webapp  # noqa: E402
import auth  # noqa: E402

PROJECTS = [{"id": 1, "slug": "cloudsix", "name": "CloudSix"}]


@pytest.fixture
def client(monkeypatch, fake):
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


def _upload(client, path: Path):
    return client.post("/p/cloudsix/upload/summary",
                       data={"cabinet": "Feel", "file": (io.BytesIO(path.read_bytes()), path.name)},
                       content_type="multipart/form-data")


def test_route_shows_clear_rejection_for_foreign_file(client, tmp_path, fake):
    r = _upload(client, _foreign(tmp_path))
    html = r.get_data(as_text=True)
    assert r.status_code == 400
    assert "Файл не загружен" in html and "не похож на «Еженедельный сводный отчёт»" in html
    assert "Загружено строк в wb_report_summary" not in html     # зелёного «успеха» быть не должно
    assert [t for t, _ in fake.inserts if t == "wb_report_summary"] == []


def test_route_warns_when_reconciliation_has_nothing_to_compare(client, tmp_path, fake, monkeypatch):
    monkeypatch.setattr(webapp, "run_reconciliation", lambda *a, **k: [])
    monkeypatch.setattr(webapp, "get_client", lambda database=None: fake)
    path = _xlsx(tmp_path / "s.xlsx", list(core.COLUMN_MAP), [_summary_row(1)])
    html = _upload(client, path).get_data(as_text=True)
    assert "Сверка не выполнена" in html            # «Расхождений: 0 / Все поля в допуске» без проверок — ложное успокоение


def test_upload_page_door_buttons_are_not_disabled_and_have_message_slot(client):
    """Баг 2026-10-02: кнопка «Загрузить» была disabled до выбора кабинета, подсказка — мелким серым.
    Пользователь жал на неё — запрос на сервер не уходил вовсе («ничего не произошло»)."""
    html = client.get("/p/cloudsix/upload").get_data(as_text=True)
    assert "data-door-message" in html and "data-door-form" in html and "data-door-file" in html
    import re
    buttons = re.findall(r"<button type=\"submit\"[^>]*>", html)
    assert buttons, "не нашли кнопки загрузки"
    assert not any("disabled" in b for b in buttons), buttons
