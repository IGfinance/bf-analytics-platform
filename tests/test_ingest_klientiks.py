"""Тесты парсера/ingestion Клиентикс.

Ключевое — устойчивость к сдвигу колонок: в 18-колоночных строках
birth_date/gender должны определяться по содержимому, а не по позиции, и
дата рождения не должна попадать в категорию. get_client замокан.
"""

from datetime import date, datetime
from pathlib import Path

import pytest

import klientiks_core as k

HEADER = (
    "Начало записи;Исполнитель;Должность исполнителя;Услуга;Имя клиента;"
    "Источник клиента;Телефон клиента;Дата изменения визита;Причина отмены;"
    "Номер карты;Комментарий;Перезаписан;Сумма;Количество завершённых клиентов;"
    "Категория психолога;Категория психиатра;Дата рождения; Пол;"
)

# 19 колонок (норма): сумма=5000, пол/дата рождения на штатных позициях
ROW_19 = "2025-04-24 21:00:00;Иванов И.И.;Врач-психиатр;Приём;Пётр;сайт;+700;" \
         "2026-03-27 11:55:50.179216;;10951;коммент;1;5000;3;;;01.01.1990;male;"

# 18 колонок (сдвиг): пропущена пустая колонка — дата рождения/пол уехали влево
ROW_18 = "2022-01-04 15:00:00;Петров П.П.;Психолог;Приём;Анна;интернет;+700;" \
         "2022-02-21 18:03:25.763341;;5836;;0;60;;;08.12.2007;female;"


def _write(tmp_path, *lines):
    p = tmp_path / "klientiks.csv"
    p.write_text(HEADER + "\n" + "\n".join(lines) + "\n", encoding="cp1251")
    return p


def test_parse_19col_standard(tmp_path):
    rows, skipped = k.parse_file(_write(tmp_path, ROW_19))
    assert skipped == 0 and len(rows) == 1
    r = rows[0]
    assert r["visit_start"] == datetime(2025, 4, 24, 21, 0, 0)
    assert r["card_number"] == "10951"
    assert r["amount"] == 5000.0
    assert r["birth_date"] == date(1990, 1, 1)
    assert r["gender"] == "male"
    # микросекунды в дате изменения обрезаются
    assert r["visit_modified"] == datetime(2026, 3, 27, 11, 55, 50)


def test_parse_18col_shift_anchors_birth_and_gender(tmp_path):
    rows, _ = k.parse_file(_write(tmp_path, ROW_18))
    r = rows[0]
    # несмотря на сдвиг — дата рождения и пол определены по содержимому
    assert r["birth_date"] == date(2007, 12, 8)
    assert r["gender"] == "female"
    # и дата рождения НЕ просочилась в категорию
    assert r["psychiatrist_category"] is None
    assert r["psychologist_category"] is None
    assert r["amount"] == 60.0


def test_parse_skips_garbage_rows(tmp_path):
    rows, skipped = k.parse_file(_write(tmp_path, ROW_19, "обрывок;строки", ""))
    assert len(rows) == 1
    assert skipped == 2  # короткие строки не потеряны тихо, а посчитаны


class FakeClient:
    def __init__(self):
        self.inserts = []

    def insert(self, table, data, column_names):
        self.inserts.append({"table": table, "data": data, "column_names": column_names})


def test_ingest_files_inserts_and_summary(tmp_path, monkeypatch):
    path = _write(tmp_path, ROW_19, ROW_18, "мусор")
    fake = FakeClient()
    captured = {}

    def fake_get_client(database=None):
        captured["db"] = database
        return fake

    monkeypatch.setattr(k, "get_client", fake_get_client)

    summary = k.ingest_files([path], project_id=2, log=lambda *_: None, database="realt")

    assert summary == {"files": 1, "rows": 2, "skipped": 1}
    assert captured["db"] == "realt"
    ins = fake.inserts[0]
    assert ins["table"] == "klientiks_operations"
    assert ins["column_names"] == k.COLUMNS
    pid_idx = k.COLUMNS.index("project_id")
    assert all(row[pid_idx] == 2 for row in ins["data"])


def test_ingest_files_empty_raises(tmp_path, monkeypatch):
    monkeypatch.setattr(k, "get_client", lambda database=None: (_ for _ in ()).throw(
        AssertionError("get_client не должен вызываться при пустом результате")))
    empty = _write(tmp_path, "мусор", "")
    with pytest.raises(ValueError, match="Не найдено ни одной строки визита"):
        k.ingest_files([empty], project_id=1)
