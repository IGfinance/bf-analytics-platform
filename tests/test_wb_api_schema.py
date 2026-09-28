"""Тесты загрузчика финансового API WB (src/wb_api_core.py).

Главное, что здесь проверяется — что словарь типов в Python и SQL-схема не
разъехались. Это ровно тот класс бага, на который проект уже наступал с
формулами метрик (см. «Один источник истины для формул» в
.claude/knowledge/architecture-standarts.md): две независимые копии одного
знания расходятся молча. Здесь копии две по необходимости — ClickHouse не
умеет отдавать типы до создания таблицы, — поэтому расхождение ловится
тестом, а не надеждой.
"""

import re
import sys
from datetime import date, datetime
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src"))

from wb_api_core import (  # noqa: E402
    BOOL, DATE, DATETIME, DETAILED_COLUMNS, DETAILED_FIELDS, FLOAT, INT, STR,
    SUMMARY_COLUMNS, SUMMARY_FIELDS, camel_to_snake, coerce, raw_to_record,
)

SCHEMA = (ROOT / "src" / "schema_wb_api.sql").read_text(encoding="utf-8")


def columns_of(table: str) -> dict[str, str]:
    """Колонки таблицы из schema_wb_api.sql: имя -> тип ClickHouse."""
    m = re.search(
        rf"CREATE TABLE IF NOT EXISTS {table}\s*\((.*?)\)\s*ENGINE",
        SCHEMA, re.S,
    )
    assert m, f"в схеме не найдена таблица {table}"
    cols = {}
    for line in m.group(1).splitlines():
        line = line.split("--")[0].strip().rstrip(",")
        if not line:
            continue
        parts = line.split(None, 1)
        if len(parts) == 2:
            cols[parts[0]] = parts[1].strip()
    return cols


CH_TO_KIND = {
    "String": STR, "Nullable(String)": STR,
    "Int64": INT, "UInt64": INT, "Nullable(Int64)": INT, "Nullable(Int32)": INT,
    "Nullable(Float64)": FLOAT,
    "Nullable(Date)": DATE, "Nullable(DateTime)": DATETIME,
    "Nullable(UInt8)": BOOL,
}


@pytest.mark.parametrize(
    "table,spec,columns",
    [
        ("wb_api_realization", DETAILED_FIELDS, DETAILED_COLUMNS),
        ("wb_api_report_summary", SUMMARY_FIELDS, SUMMARY_COLUMNS),
    ],
)
def test_python_spec_matches_sql_schema(table, spec, columns):
    ch = columns_of(table)
    # служебные колонки, которых нет в spec: их проставляет не API
    service = {"cabinet", "extra_fields", "loaded_at"}
    sql_data_cols = set(ch) - service

    assert sql_data_cols == set(spec), (
        f"{table}: разошлись SQL-схема и DETAILED/SUMMARY_FIELDS.\n"
        f"  только в SQL:    {sorted(sql_data_cols - set(spec))}\n"
        f"  только в Python: {sorted(set(spec) - sql_data_cols)}"
    )

    for col, kind in spec.items():
        expected = CH_TO_KIND.get(ch[col])
        assert expected is not None, f"{table}.{col}: неизвестный тип ClickHouse {ch[col]!r}"
        assert expected == kind, f"{table}.{col}: SQL {ch[col]} vs Python {kind!r}"

    # порядок колонок в insert должен совпадать с тем, что ждёт таблица
    assert set(columns) == sql_data_cols | {"cabinet", "extra_fields"}


@pytest.mark.parametrize("camel,snake", [
    ("rrdId", "rrd_id"),
    ("forPay", "for_pay"),
    ("paidStorage", "paid_storage"),
    ("isKgvpV2", "is_kgvp_v2"),
    ("salePriceWholesaleDiscountPrc", "sale_price_wholesale_discount_prc"),
    ("vwNds", "vw_nds"),
    ("b2bCustomerTin", "b2b_customer_tin"),
    ("spp", "spp"),
    ("sku", "sku"),
    ("title", "title"),
])
def test_camel_to_snake(camel, snake):
    assert camel_to_snake(camel) == snake


def test_money_arrives_as_string_and_is_parsed():
    """WB отдаёт деньги строками — их нельзя просто положить в Float64."""
    assert coerce(FLOAT, "3058674.41") == pytest.approx(3058674.41)
    assert coerce(FLOAT, "0") == 0.0
    assert coerce(FLOAT, 58) == 58.0


def test_empty_string_is_null_not_zero():
    """WB присылает "" вместо пропуска поля — ноль здесь был бы враньём."""
    assert coerce(FLOAT, "") is None
    assert coerce(DATETIME, "") is None
    assert coerce(DATE, "") is None
    assert coerce(STR, "") is None
    assert coerce(INT, "") is None


def test_dates_and_datetimes():
    assert coerce(DATE, "2026-08-17") == date(2026, 8, 17)
    assert coerce(DATETIME, "2026-07-08T06:49:22Z") == datetime(2026, 7, 8, 6, 49, 22)
    # у части строк приходит только дата там, где ждём datetime
    assert coerce(DATETIME, "2026-08-17") == datetime(2026, 8, 17, 0, 0, 0)
    assert coerce(DATE, "не дата") is None


def test_bools():
    assert coerce(BOOL, False) == 0
    assert coerce(BOOL, True) == 1
    assert coerce(BOOL, "true") == 1
    assert coerce(BOOL, "false") == 0


def test_sku_and_tech_size_stay_strings():
    """Баркод и размер выглядят числами, но числами быть не должны:
    ведущие нули значимы, а techSize бывает 'XL'."""
    assert DETAILED_FIELDS["sku"] is STR
    assert DETAILED_FIELDS["tech_size"] is STR
    assert DETAILED_FIELDS["sticker_id"] is STR
    assert coerce(STR, "2050454190183") == "2050454190183"


def test_unknown_field_goes_to_extra_and_is_reported():
    raw = {"rrdId": 1, "forPay": "10.5", "totallyNewFieldFromWb": "42"}
    rec, unmapped = raw_to_record(raw, "CloudSix", DETAILED_FIELDS)
    assert rec["rrd_id"] == 1
    assert rec["for_pay"] == pytest.approx(10.5)
    assert unmapped == ["totallyNewFieldFromWb"]
    assert rec["extra_fields"] == {"totallyNewFieldFromWb": "42"}


def test_optional_fields_absent_do_not_break_record():
    """В выборке 1005 строк набор полей разный: bonusTypeName и
    rebillLogisticOrg есть не везде. Отсутствие поля — не ошибка."""
    raw = {"rrdId": 7, "reportId": 1}
    rec, unmapped = raw_to_record(raw, "CloudSix", DETAILED_FIELDS)
    assert unmapped == []
    assert "bonus_type_name" not in rec
    # insert собирается через .get(), поэтому отсутствующая колонка → None
    row = [rec.get(c) for c in DETAILED_COLUMNS]
    assert row[DETAILED_COLUMNS.index("bonus_type_name")] is None
    assert row[DETAILED_COLUMNS.index("cabinet")] == "CloudSix"


def test_no_stale_v5_field_names_left():
    """Имена мёртвого метода v5 не должны остаться нигде в схеме/загрузчике."""
    dead = ["ppvz_for_pay", "delivery_rub", "storage_fee", "rr_dt",
            "ppvz_spp_prc", "ppvz_kvw_prc", "site_country", "is_legal_entity"]
    core = (ROOT / "src" / "wb_api_core.py").read_text(encoding="utf-8")
    for name in dead:
        assert name not in SCHEMA, f"в schema_wb_api.sql осталось v5-имя {name}"
        assert name not in core, f"в wb_api_core.py осталось v5-имя {name}"


# --- поведение _post на нестандартных ответах -------------------------------
# Регресс на находку 2026-09-27: период без отчётов WB отдаёт 200 с ПУСТЫМ
# телом, а не с "[]". resp.json() на таком падает ValueError, и при дозагрузке
# истории это выглядело как сбой куска (ARB/Feel/NoxLab — до 2025-03 отчётов
# нет вовсе). Пустой ответ обязан читаться как «отчётов нет».

class _FakeResp:
    def __init__(self, text, status=200):
        self.text = text
        self.status_code = status
        self.headers = {}

    def json(self):
        import json as _json
        return _json.loads(self.text)


def _post_with(monkeypatch, resp):
    import wb_api_core as core
    monkeypatch.setattr(core.requests, "post", lambda *a, **k: resp)
    pacer = core._Pacer(interval=0, log=lambda *_: None)
    return core._post("tok", "/p", {}, pacer, log=lambda *_: None)


def test_empty_body_means_no_reports(monkeypatch):
    assert _post_with(monkeypatch, _FakeResp("")) == []
    assert _post_with(monkeypatch, _FakeResp("   \n")) == []


def test_json_null_means_no_reports(monkeypatch):
    assert _post_with(monkeypatch, _FakeResp("null")) == []


def test_valid_body_is_returned(monkeypatch):
    assert _post_with(monkeypatch, _FakeResp('[{"reportId": 1}]')) == [{"reportId": 1}]


def test_garbage_body_raises_with_context(monkeypatch):
    import pytest as _pytest
    with _pytest.raises(RuntimeError, match="не разбирается как JSON"):
        _post_with(monkeypatch, _FakeResp("<html>502 Bad Gateway</html>"))


# --- пагинация detailed ------------------------------------------------------
# Регресс на находку 2026-09-28: строки в ответе НЕ отсортированы по rrdId.
# Курсор должен браться от ПОСЛЕДНЕЙ строки страницы; курсор от max(rrdId)
# перепрыгивает через строки и теряет данные молча.

def _pages_via(monkeypatch, pages):
    """Гоняет fetch_detailed_pages по подготовленным ответам, возвращает
    список курсоров, с которыми ушли запросы."""
    import wb_api_core as core
    sent = []

    def fake_post(token, path, body, pacer, log=print):
        sent.append(body["rrdId"])
        return pages[len(sent) - 1]

    monkeypatch.setattr(core, "_post", fake_post)
    pacer = core._Pacer(interval=0, log=lambda *_: None)
    got = list(core.fetch_detailed_pages("tok", 1, pacer, log=lambda *_: None))
    return sent, got


def test_cursor_takes_last_row_not_max(monkeypatch):
    import wb_api_core as core
    # страница длиной PAGE_LIMIT, неотсортированная: max НЕ равен последнему
    big = [{"rrdId": 500}] + [{"rrdId": i} for i in range(100, 100 + core.PAGE_LIMIT - 2)] + [{"rrdId": 200}]
    assert len(big) == core.PAGE_LIMIT
    assert max(r["rrdId"] for r in big) != big[-1]["rrdId"]
    sent, got = _pages_via(monkeypatch, [big, [{"rrdId": 201}]])
    # второй запрос обязан уйти с rrdId ПОСЛЕДНЕЙ строки (200), а не с max (10097)
    assert sent == [0, 200], f"курсор взят неверно: {sent}"
    assert len(got) == 2


def test_short_page_ends_pagination(monkeypatch):
    import wb_api_core as core
    sent, got = _pages_via(monkeypatch, [[{"rrdId": 7}]])
    assert sent == [0] and len(got) == 1


def test_repeating_cursor_raises(monkeypatch):
    import pytest as _pytest
    import wb_api_core as core
    page = [{"rrdId": 42}] * core.PAGE_LIMIT
    with _pytest.raises(RuntimeError, match="курсор повторяется"):
        _pages_via(monkeypatch, [page, page])
