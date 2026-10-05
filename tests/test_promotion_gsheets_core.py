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


OZON_HEADER = ["SKU", "Название товара", "Инструмент", "Место размещения",
               "ID кампании", "Расход, ₽", "ДРР в продвижении, %",
               "Продажи в продвижении, ₽", "Продано товаров, шт",
               "Продажи в продвижении с заказов модели, ₽",
               "Продано товаров модели, шт", "CTR, %", "Показы", "Клики",
               "Добавления в корзину, шт", "Конверсия в корзину, %", "ДРР, %",
               "Затраты на заказ, ₽", "Средняя стоимость клика, ₽", "",
               "Дата", "Артикул"]


def test_parse_ozon_promotion_basic_row():
    values = [OZON_HEADER, [
        "3010703510", "Внешний аккумулятор повербанк", "Оплата за клик", "Поиск",
        "24112754", "2\xa0731", "15", "18\xa0452", "7", "-", "-", "2", "9\xa0788",
        "189", "32", "17", "3", "390", "14", "", "01.08.2026", "PowerBank_New_Mini_Red_v5",
    ]]
    rows, skipped = g.parse_ozon_promotion(values)
    assert skipped == 0
    assert len(rows) == 1
    r = rows[0]
    assert r["sku"] == "3010703510"
    assert r["product_name"] == "Внешний аккумулятор повербанк"
    assert r["tool"] == "Оплата за клик"
    assert r["placement"] == "Поиск"
    assert r["campaign_id"] == "24112754"
    assert r["spend_rub"] == 2731.0
    assert r["drr_in_promotion_pct"] == 15.0
    assert r["sales_in_promotion_rub"] == 18452.0
    assert r["items_sold"] == 7.0
    assert r["sales_in_promotion_model_rub"] is None
    assert r["items_sold_model"] is None
    assert r["ctr_pct"] == 2.0
    assert r["impressions"] == 9788.0
    assert r["clicks"] == 189.0
    assert r["cart_adds"] == 32.0
    assert r["cart_conversion_pct"] == 17.0
    assert r["drr_pct"] == 3.0
    assert r["cost_per_order_rub"] == 390.0
    assert r["avg_click_cost_rub"] == 14.0
    assert r["promo_date"] == date(2026, 8, 1)
    assert r["article"] == "PowerBank_New_Mini_Red_v5"
    assert r["row_num"] == 2
    assert r["source_file"] == g.OZON_PROMOTION_SOURCE


def test_parse_ozon_promotion_skips_rows_without_sku():
    values = [OZON_HEADER, [""] * 22]
    rows, skipped = g.parse_ozon_promotion(values)
    assert rows == []
    assert skipped == 1


REFERENCE_VALUES = [
    ["Для WB", "", "", "Для Ozon"],
    ["Кампания", "Артикул", "", "SKU", "Артикул"],
    ["1446931490/GSM_Round_Black_v2/Поиск", "GSM_Round_Black_v2", "",
     "3134230813", "TV_Lampa"],
    ["1446931491/GSM_Round_v4/Поиск", "GSM_Round_v4", "",
     "3010572109", "PowerBank_Mini_Каб_20_v3"],
    ["", "", "", "4068406020", "повер 10 с беспр. зарядом"],  # WB-блок уже закончился
]


def test_parse_wb_promotion_reference():
    rows, skipped = g.parse_wb_promotion_reference(REFERENCE_VALUES)
    assert skipped == 1  # последняя строка без значения в столбце A
    assert len(rows) == 2
    assert rows[0] == {
        "row_num": 3, "source_file": g.WB_PROMOTION_REFERENCE_SOURCE,
        "campaign": "1446931490/GSM_Round_Black_v2/Поиск",
        "article": "GSM_Round_Black_v2",
    }


def test_parse_ozon_promotion_reference():
    rows, skipped = g.parse_ozon_promotion_reference(REFERENCE_VALUES)
    assert skipped == 0
    assert len(rows) == 3
    assert rows[-1] == {
        "row_num": 5, "source_file": g.OZON_PROMOTION_REFERENCE_SOURCE,
        "sku": "4068406020", "article": "повер 10 с беспр. зарядом",
    }


class _FakeClient:
    def __init__(self):
        self.inserts = []

    def insert(self, table, data, column_names):
        self.inserts.append((table, data, column_names))


def test_ingest_stamps_one_loaded_at_per_load(monkeypatch):
    """Все строки одной загрузки несут одну метку loaded_at — по ней *_current берёт свежий снимок."""
    fake = _FakeClient()
    monkeypatch.setattr(g, "read_tab", lambda sid, name: [WB_HEADER, [
        "1", "camp/A", "Ручная", "01.08.2026", "Баланс", "100", "d1", "", "A"],
        ["2", "camp/B", "Ручная", "02.08.2026", "Баланс", "200", "d2", "", "B"]])
    monkeypatch.setattr(g, "get_client", lambda database=None: fake)
    summary = g.ingest_wb_promotion(1, log=lambda *_: None, spreadsheet_id="x")
    assert summary == {"rows": 2, "skipped": 0}
    (table, data, cols), = fake.inserts
    assert table == "wb_promotion" and cols[-1] == "loaded_at"
    stamps = {row[-1] for row in data}
    assert len(stamps) == 1


def test_ingest_all_one_tab_failure_does_not_stop_others(monkeypatch):
    calls = []

    def ok(name):
        def f(project_id, log=print, database=None, spreadsheet_id=None):
            calls.append(name)
            return {"rows": 1, "skipped": 0}
        return f

    def boom(project_id, log=print, database=None, spreadsheet_id=None):
        calls.append("boom")
        raise ValueError("пусто")

    monkeypatch.setattr(g, "PROMOTION_TABS", [("A", ok("A")), ("B", boom), ("C", ok("C"))])
    res = g.ingest_all(1, log=lambda *_: None)
    assert calls == ["A", "boom", "C"]
    assert res["A"] == {"rows": 1, "skipped": 0}
    assert res["B"] == {"error": "пусто"}
    assert res["C"] == {"rows": 1, "skipped": 0}


def test_schema_views_read_only_latest_snapshot():
    from pathlib import Path
    sql = (Path(g.SCRIPT_DIR) / "schema_promotion.sql").read_text(encoding="utf-8")
    assert "FROM wb_promotion_current" in sql and "FROM ozon_promotion_current" in sql
    assert "max(loaded_at)" in sql
