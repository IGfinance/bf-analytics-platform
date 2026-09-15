"""Тесты парсера расходов Реальта (вкладка «Остальные расходы»).

Google Sheets API не дёргаем — parse_expenses работает с уже прочитанными
значениями (list[list[str]]). Вкладка — матрица: колонка [1] — метки месяцев
(«янв.-25»), колонки [2..] — статьи расходов, у каждой две шапки: строка
«Статья» (имя) и строка «Дата/Тип» (группа/тип). Блоки идут стопкой (2025,
пустая строка, 2026), набор статей между блоками может отличаться.
"""

from datetime import date

import realt_gsheets_core as g


def _block(names, types, month_rows):
    """Собирает блок: строка Статья, строка Дата/Тип, затем строки-месяцы.

    names/types — списки для колонок начиная с [2]; month_rows — список
    (метка_месяца, [суммы по колонкам с [2]]).
    """
    hdr_name = ["", "Статья"] + names
    hdr_type = ["", "Дата/Тип"] + types
    rows = [hdr_name, hdr_type]
    for label, amounts in month_rows:
        rows.append(["", label] + amounts)
    return rows


def test_parse_basic_block():
    values = _block(
        names=["НДФЛ - 2 этаж", "Аренда - 3 этаж"],
        types=["Налоги ФОТ", "Аренда+коммуналка"],
        month_rows=[
            ("янв.-25", ["-38\xa0844", "-182\xa0876"]),
            ("февр.-25", ["-37\xa0691", "-"]),  # аренда «-» → пропуск
        ],
    )
    rows, skipped = g.parse_expenses(values)
    recs = {(r["period"], r["article"]): r for r in rows}
    assert len(rows) == 3
    assert recs[(date(2025, 1, 1), "НДФЛ - 2 этаж")]["amount"] == -38844.0
    assert recs[(date(2025, 1, 1), "НДФЛ - 2 этаж")]["expense_type"] == "Налоги ФОТ"
    assert recs[(date(2025, 1, 1), "Аренда - 3 этаж")]["amount"] == -182876.0
    assert recs[(date(2025, 2, 1), "НДФЛ - 2 этаж")]["amount"] == -37691.0
    assert (date(2025, 2, 1), "Аренда - 3 этаж") not in recs  # «-» пропущен
    assert skipped == 1


def test_parse_multiblock_different_articles():
    block25 = _block(
        names=["Ком услуги, интернет - 2 этаж"], types=["Аренда+коммуналка"],
        month_rows=[("дек.-25", ["-12\xa0587"])],
    )
    block26 = _block(
        names=["Ком услуги - 2 этаж"], types=["Аренда+коммуналка"],
        month_rows=[("янв.-26", ["-10\xa0530"])],
    )
    values = block25 + [[""]] + block26  # пустая строка между блоками
    rows, _ = g.parse_expenses(values)
    by_period = {r["period"]: r for r in rows}
    assert by_period[date(2025, 12, 1)]["article"] == "Ком услуги, интернет - 2 этаж"
    assert by_period[date(2026, 1, 1)]["article"] == "Ком услуги - 2 этаж"
    assert by_period[date(2026, 1, 1)]["amount"] == -10530.0


def test_parse_is_shaa_flag():
    values = _block(
        names=["НДФЛ - ШАА", "Аренда - 2 этаж"],
        types=["Налоги ФОТ", "Аренда+коммуналка"],
        month_rows=[("мар.-25", ["-523", "-259\xa0200"])],
    )
    rows, _ = g.parse_expenses(values)
    flags = {r["article"]: r["is_shaa"] for r in rows}
    assert flags["НДФЛ - ШАА"] is True
    assert flags["Аренда - 2 этаж"] is False


def test_parse_metadata_fields():
    values = _block(
        names=["Аренда - 2 этаж"], types=["Аренда+коммуналка"],
        month_rows=[("янв.-25", ["-259\xa0200"])],
    )
    (r,), _ = g.parse_expenses(values)
    assert r["source_file"] == g.EXPENSES_SOURCE
    assert r["col_num"] == 2          # первая статья — колонка [2]
    assert r["row_num"] == 3          # 3-я строка блока (1-based): Статья, Дата/Тип, месяц


def test_ru_month_parses_irregular_forms():
    assert g._ru_month("янв.-25") == date(2025, 1, 1)
    assert g._ru_month("февр.-25") == date(2025, 2, 1)
    assert g._ru_month("мар.-25") == date(2025, 3, 1)
    assert g._ru_month("мая-25") == date(2025, 5, 1)    # нерегулярная форма без точки
    assert g._ru_month("сент.-26") == date(2026, 9, 1)
    assert g._ru_month("нояб.-25") == date(2025, 11, 1)
    assert g._ru_month("дек.-26") == date(2026, 12, 1)
    assert g._ru_month("Итого") is None
    assert g._ru_month("") is None
