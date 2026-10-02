"""Тесты парсеров «Продвижение CS» (Google-Таблица WB+Ozon продвижение).

Google Sheets API не дёргаем — parse_* работают с уже прочитанными
значениями (list[list[str]]), как и в test_realt_payroll.py.
"""

from datetime import date

import promotion_gsheets_core as g

WB_HEADER = ["ID кампании", "Кампания", "Раздел", "Дата", "Источник списания",
             "Сумма", "Номер документа", "", "Артикул"]


def test_parse_wb_promotion_basic_row():
    values = [WB_HEADER, [
        "38141316", "1240796025/Cloud_Bank_20_Cab_v2/Поиск", "Ручная",
        "31.08.2026", "Баланс", "283", "313667534", "", "Cloud_Bank_20_Cab_v2",
    ]]
    rows, skipped = g.parse_wb_promotion(values)
    assert skipped == 0
    assert len(rows) == 1
    r = rows[0]
    assert r["campaign_id"] == "38141316"
    assert r["campaign"] == "1240796025/Cloud_Bank_20_Cab_v2/Поиск"
    assert r["section"] == "Ручная"
    assert r["promo_date"] == date(2026, 8, 31)
    assert r["write_off_source"] == "Баланс"
    assert r["amount"] == 283.0
    assert r["document_number"] == "313667534"
    assert r["article"] == "Cloud_Bank_20_Cab_v2"
    assert r["row_num"] == 2
    assert r["source_file"] == g.WB_PROMOTION_SOURCE


def test_parse_wb_promotion_thousands_separator_amount():
    values = [WB_HEADER, [
        "38865304", "1298868971/PowerBank_New_Mini_Red_v10/Поиск", "Ручная",
        "01.08.2026", "Баланс", "1\xa0466", "309282476", "", "PowerBank_New_Mini_Red_v10",
    ]]
    (r,), _ = g.parse_wb_promotion(values)
    assert r["amount"] == 1466.0


def test_parse_wb_promotion_skips_rows_without_campaign():
    values = [WB_HEADER, ["", "", "", "", "", "", "", "", ""]]
    rows, skipped = g.parse_wb_promotion(values)
    assert rows == []
    assert skipped == 1
