"""Тесты ingestion-обёртки card_statement_pdf.ingest_files.

Парсинг PDF (parse_pdf) требует pdftotext и реального PDF, поэтому он
замокан — проверяется извлечённая в этап 2 логика: project_id,
конвертация дат через to_date, вызов insert, сводка с cardholders.
"""

from datetime import date
from pathlib import Path

import pytest

import card_statement_pdf as card


def make_row(**over):
    row = {
        "cardholder": "Иванов И.И.",
        "source_bank": "Т-Банк",
        "account_number": "40817810000000000001",
        "card_number": "*1234",
        "operation_date": "05.09.2026",
        "processing_date": "06.09.2026",
        "amount": 1500.0,
        "signed_amount": -1500.0,
        "description": "Покупка",
        "row_num": 1,
        "source_file": "spravka.pdf",
    }
    row.update(over)
    return row


class FakeClient:
    def __init__(self):
        self.inserts = []

    def insert(self, table, data, column_names):
        self.inserts.append({"table": table, "data": data, "column_names": column_names})


def test_ingest_files_converts_dates_and_inserts(monkeypatch):
    rows = [
        make_row(),
        make_row(cardholder="Петров П.П.", row_num=2, operation_date="",
                 processing_date="10.09.2026", source_file="spravka2.pdf"),
    ]
    # parse_pdf вызывается по файлу — вернём заготовленные строки
    monkeypatch.setattr(card, "parse_pdf", lambda path: rows)

    fake = FakeClient()
    captured = {}

    def fake_get_client(database=None):
        captured["database"] = database
        return fake

    monkeypatch.setattr(card, "get_client", fake_get_client)

    summary = card.ingest_files(
        [Path("spravka.pdf")], project_id=7, log=lambda *_: None, database="proj_testdb"
    )

    assert summary == {"files": 1, "rows": 2, "cardholders": ["Иванов И.И.", "Петров П.П."]}
    assert captured["database"] == "proj_testdb"

    ins = fake.inserts[0]
    assert ins["table"] == "card_statements"
    assert ins["column_names"] == card.COLUMNS

    pid_idx = card.COLUMNS.index("project_id")
    op_idx = card.COLUMNS.index("operation_date")
    proc_idx = card.COLUMNS.index("processing_date")

    assert all(row[pid_idx] == 7 for row in ins["data"])
    # строковые даты сконвертированы в date; пустая строка -> None
    assert ins["data"][0][op_idx] == date(2026, 9, 5)
    assert ins["data"][1][op_idx] is None
    assert ins["data"][1][proc_idx] == date(2026, 9, 10)


def test_ingest_files_empty_raises(monkeypatch):
    monkeypatch.setattr(card, "parse_pdf", lambda path: [])

    def boom(database=None):
        raise AssertionError("get_client не должен вызываться при пустом результате")

    monkeypatch.setattr(card, "get_client", boom)

    with pytest.raises(ValueError, match="Не найдено ни одной транзакции"):
        card.ingest_files([Path("empty.pdf")], project_id=1)
