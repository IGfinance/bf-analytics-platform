"""Тесты парсера ФОТ Реальта (вкладка «Импорт ФОТ»).

Google Sheets API не дёргаем — parse_payroll работает с уже прочитанными
значениями (list[list[str]]). Проверяем фильтр строк-данных (Роль ~ «ФОТ»),
нормализацию русских чисел/процентов/дат и сбор extra_columns.
"""

import realt_gsheets_core as g


def _row(**kw):
    """Собирает 42-колоночную строку вкладки из позиций _POS + доп. ячеек."""
    row = [""] * 42
    for field, idx in g._POS.items():
        if field in kw:
            row[idx] = kw[field]
    for idx, val in kw.get("_extra", {}).items():
        row[idx] = val
    return row


HEADER = [""] * 42
HEADER[8] = "План часов"


def test_parse_filters_non_fot_rows():
    values = [
        HEADER,
        _row(period="28.02.2025", employee_id="АрсТБ", role="ФОТ Психиатры",
             accrued_total="134\xa0400", to_pay="134 400,00"),
        _row(role="Роль"),          # строка-заголовок секции — отсекается
        _row(role=""),              # пустая — отсекается
        _row(period="Январь 2026", role="Итого"),  # итог — отсекается
    ]
    rows, skipped = g.parse_payroll(values)
    assert len(rows) == 1
    assert skipped == 3


def test_parse_normalizes_numbers_dates_percent():
    values = [HEADER, _row(
        period="28.02.2025", employee_id="АрсТБ_ТД", department="3 этаж",
        role="ФОТ Психиатры", category="Опытный", pay_type="Оклад",
        salary="120\xa0000,00", accrued_total="134\xa0400", to_pay="134\xa0400,00",
        ndfl="-2\xa0617,00", contributions="-6\xa0077,75", revenue="585\xa0127",
        fot_revenue_share="22,97%",
    )]
    (r,), _ = g.parse_payroll(values)
    from datetime import date
    assert r["period"] == date(2025, 2, 28)
    assert r["employee_id"] == "АрсТБ_ТД"
    assert r["salary"] == 120000.0
    assert r["accrued_total"] == 134400.0
    assert r["ndfl"] == -2617.0
    assert r["contributions"] == -6077.75
    assert r["fot_revenue_share"] == 22.97
    assert r["row_num"] == 2
    assert r["source_file"] == g.PAYROLL_SOURCE


def test_dash_and_empty_become_none():
    (r,), _ = g.parse_payroll([HEADER, _row(role="ФОТ Психологи", salary="-", to_pay="")])
    assert r["salary"] is None
    assert r["to_pay"] is None


def test_unmapped_columns_go_to_extra():
    values = [HEADER, _row(role="ФОТ Управление", _extra={8: "138"})]  # «План часов»
    (r,), _ = g.parse_payroll(values)
    assert r["extra_columns"]["План часов"] == "138"
    # канонические поля в extra не дублируются
    assert "employee_id" not in r["extra_columns"]


def test_num_helper_handles_ru_format():
    assert g._num("120\xa0000,00") == 120000.0
    assert g._num("-6 077,75") == -6077.75
    assert g._num("-") is None
    assert g._num("") is None
    assert g._pct("22,97%") == 22.97
