"""Тесты ingestion-обёртки bank_statement_1c.ingest_files.

Проверяют извлечённую в этап 1 логику (project_id, пустой результат,
вызов insert, сводка), а не парсинг per se — парсинг гоняется на
реальном синтетическом 1С-файле, но без похода в ClickHouse (get_client
замокан).
"""

from datetime import date
from pathlib import Path

import pytest

import bank_statement_1c as bank


SAMPLE_1C = """1CClientBankExchange
Отправитель=Тест Банк
РасчСчет=40802810100000000001
КонецРасчСчет
СекцияДокумент=Платежное поручение
Номер=1
Дата=05.09.2026
Сумма=1000.50
ДатаПоступило=05.09.2026
Плательщик=ООО Плательщик
ПлательщикИНН=7700000000
ПлательщикСчет=40702810900000000002
ПолучательСчет=40802810100000000001
НазначениеПлатежа=Оплата входящая
КонецДокумента
СекцияДокумент=Платежное поручение
Номер=2
Дата=06.09.2026
Сумма=500.00
ДатаСписано=06.09.2026
Получатель=ООО Получатель
ПолучательИНН=7800000000
ПолучательСчет=40702810900000000003
НазначениеПлатежа=Оплата исходящая
КонецДокумента
КонецФайла
"""


class FakeClient:
    def __init__(self):
        self.inserts = []

    def insert(self, table, data, column_names):
        self.inserts.append({"table": table, "data": data, "column_names": column_names})


@pytest.fixture
def sample_file(tmp_path):
    path = tmp_path / "vypiska.txt"
    path.write_text(SAMPLE_1C, encoding="1251")
    return path


def test_ingest_files_parses_and_inserts(sample_file, monkeypatch):
    fake = FakeClient()
    captured = {}

    def fake_get_client(database=None):
        captured["database"] = database
        return fake

    monkeypatch.setattr(bank, "get_client", fake_get_client)

    logs = []
    summary = bank.ingest_files(
        [sample_file], project_id=42, log=logs.append, database="proj_testdb"
    )

    # сводка
    assert summary == {"files": 1, "rows": 2, "extra_columns": []}

    # database проброшен в get_client
    assert captured["database"] == "proj_testdb"

    # один insert в нужную таблицу с полным набором колонок
    assert len(fake.inserts) == 1
    ins = fake.inserts[0]
    assert ins["table"] == "bank_statements"
    assert ins["column_names"] == bank.COLUMNS
    assert len(ins["data"]) == 2

    # project_id проставлен в каждую строку (первая колонка COLUMNS)
    pid_idx = bank.COLUMNS.index("project_id")
    assert all(row[pid_idx] == 42 for row in ins["data"])

    # направления и знак суммы разобраны корректно
    dir_idx = bank.COLUMNS.index("direction")
    signed_idx = bank.COLUMNS.index("signed_amount")
    date_idx = bank.COLUMNS.index("effective_date")
    by_dir = {row[dir_idx]: row for row in ins["data"]}
    assert by_dir["in"][signed_idx] == 1000.50
    assert by_dir["out"][signed_idx] == -500.00
    assert by_dir["in"][date_idx] == date(2026, 9, 5)


def test_ingest_files_empty_raises(monkeypatch, tmp_path):
    # get_client не должен вызываться, если транзакций нет
    def boom(database=None):
        raise AssertionError("get_client не должен вызываться при пустом результате")

    monkeypatch.setattr(bank, "get_client", boom)

    empty = tmp_path / "empty.txt"
    empty.write_text("1CClientBankExchange\nКонецФайла\n", encoding="1251")

    with pytest.raises(ValueError, match="Не найдено ни одной транзакции"):
        bank.ingest_files([empty], project_id=1)
