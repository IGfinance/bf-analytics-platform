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
