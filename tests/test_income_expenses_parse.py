import pytest
from datetime import date
from pathlib import Path
from wb_income_expenses_core import parse_income_expenses

MARCH = Path("/Users/ilya/Downloads/Gmail/Март.xlsx")
AUGUST = Path("/Users/ilya/Downloads/Gmail/Август.xlsx")


def test_parse_period_march():
    result = parse_income_expenses(MARCH)
    assert result["period_start"] == date(2026, 3, 1)
    assert result["period_end"] == date(2026, 3, 31)


def test_parse_period_august_partial():
    result = parse_income_expenses(AUGUST)
    assert result["period_start"] == date(2026, 8, 1)
    assert result["period_end"] == date(2026, 8, 23)


def test_parse_source_file():
    result = parse_income_expenses(MARCH)
    assert result["source_file"] == "Март.xlsx"


def test_parse_numeric_totals_march():
    result = parse_income_expenses(MARCH)
    assert isinstance(result["n_sales"], int)
    assert result["n_sales"] > 0
    assert isinstance(result["n_returns"], int)
    assert result["n_returns"] >= 0
    assert result["sales_rub"] > 0
    assert result["returns_rub"] <= 0
    assert result["logistics_rub"] <= 0
    assert result["commission_rub"] <= 0
    assert 5_000_000 < result["total_rub"] < 8_000_000


def test_parse_known_totals_march():
    result = parse_income_expenses(MARCH)
    assert result["n_sales"] == 4614
    assert result["n_returns"] == 193
    assert abs(result["sales_rub"] - 10_037_087.19) < 1.0
    assert abs(result["returns_rub"] - (-441_771.12)) < 1.0
    assert abs(result["logistics_rub"] - (-350_448.69)) < 1.0
    assert abs(result["fines_rub"] - (-2_043.70)) < 1.0
    assert abs(result["commission_rub"] - (-2_863_919.82)) < 1.0
    assert abs(result["acquiring_rub"] - (-290_089.42)) < 1.0
    assert abs(result["losses_rub"] - 12_947.03) < 1.0
    assert abs(result["bonuses_rub"] - 0.0) < 1.0
    assert abs(result["loyalty_rub"] - 0.0) < 1.0
    assert abs(result["total_rub"] - 6_098_540.66) < 1.0


def test_parse_missing_file():
    with pytest.raises(Exception):
        parse_income_expenses(Path("/tmp/nonexistent.xlsx"))
