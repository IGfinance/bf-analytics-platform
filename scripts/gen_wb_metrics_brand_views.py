#!/usr/bin/env python3
"""
Генерирует БРЕНДОВЫЕ варианты вьюх метрик WB из КАНОНИЧЕСКИХ файлов.

Зачем: в адаптерных отчётах нужен столбец «Бренд» после «Кабинета». Бренд —
строка отчёта (wb_reports.brand / wb_api_realization.brand), поэтому это ещё
одно ИЗМЕРЕНИЕ той же формулы, а не новая формула. Как и API-вариант
(gen_wb_metrics_api_view.py), бренд-вариант получается механической заменой
из канонического файла — формула остаётся в одном месте.

Канонические вьюхи (wb_metrics_by_sku_month, wb_metrics_by_cabinet_month и их
_api) НЕ меняются: на них стоят Модель 49, SKU-дашборды и сверки, а добавление
бренда в их зерно размножило бы строки артикула (у одного артикула бывают
строки и с брендом, и без — служебные) и могло задвоить себестоимость.
Новые вьюхи живут рядом:

    wb_metrics_by_sku_brand_month        / _api   — кабинет × месяц × артикул × бренд
    wb_metrics_by_cabinet_brand_month    / _api   — кабинет × месяц × бренд

ПУСТОЙ БРЕНД — отдельное значение 'Без бренда', без перераспределения по
артикулу (решение владельца 2026-10-04): честно видно, сколько денег не
привязано к бренду. Значения бренда берутся как есть из отчёта.

Себестоимость: cogs_agg группируется по тому же бренду строки, и джойн идёт
по (cabinet, month, sku, brand) — один-к-одному, как в каноническом файле.
ИНВАРИАНТ (проверяется tests/test_wb_metrics_brand_view.py и вручную на
проде): сумма любой метрики по брендам внутри (кабинет, месяц) равна
значению канонической wb_metrics_by_cabinet_month.

Запуск:
    python3 scripts/gen_wb_metrics_brand_views.py          # записать файл
    python3 scripts/gen_wb_metrics_brand_views.py --check  # только проверить
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SRC = REPO / "src"

CANON_SKU = SRC / "schema_wb_metrics_views_sku.sql"
CANON_CAB = SRC / "schema_wb_metrics_views.sql"
OUT = SRC / "schema_wb_metrics_views_brand.sql"

API_SOURCE_TABLE = "wb_api_realization_as_reports"

# Внутреннее имя — НЕ brand: в ClickHouse псевдоним с именем колонки
# перекрывает её во всех выражениях того же SELECT (циклический псевдоним).
BRAND_EXPR = "coalesce(nullIf(trim(brand), ''), 'Без бренда')"

HEADER = f"""-- СГЕНЕРИРОВАННЫЙ ФАЙЛ. Не правьте руками.
--
-- Источник: {CANON_SKU.name} + {CANON_CAB.name}
-- Генератор: scripts/gen_wb_metrics_brand_views.py
--
-- Те же метрики WB, что в канонических вьюхах, с дополнительным измерением
-- «бренд» (строка отчёта: wb_reports.brand для .xlsx, brand у API). Пустой
-- бренд = 'Без бренда', без перераспределения по артикулу. Формула взята из
-- канонических файлов дословно; изменены только группировка и ключ джойна
-- себестоимости. Канонические вьюхи не затронуты.
--
-- Применять на проде ТОЛЬКО под пользователем с правом DDL (default), порядок:
-- sku-вьюха, потом кабинетная (она читает sku-вьюху). Вьюхи новые, поэтому
-- CREATE VIEW IF NOT EXISTS ничего существующего не перезаписывает.
--
-- Правите формулу — правьте КАНОНИЧЕСКИЙ файл и прогоняйте генератор.
"""


def _sub(text: str, old: str, new: str, expected: int) -> str:
    """Замена с проверкой числа вхождений: если канонический файл
    переписали и шаблон не нашёлся — генератор падает, а не молча выдаёт
    вьюху без бренда."""
    n = text.count(old)
    if n != expected:
        raise SystemExit(
            f"генератор устарел: ожидал {expected} вхождений, нашёл {n}:\n{old!r}")
    return text.replace(old, new)


def brand_sku(text: str) -> str:
    """Каноническая sku-вьюха → её бренд-вариант."""
    out = text
    # base: бренд строки как измерение
    out = _sub(out,
               "        cabinet,\n        toDateTime(toStartOfMonth(sale_date)) + INTERVAL 12 HOUR AS month,",
               "        cabinet,\n        toDateTime(toStartOfMonth(sale_date)) + INTERVAL 12 HOUR AS month,\n"
               f"        {BRAND_EXPR} AS brand_key,", 1)
    # cogs_agg: тот же бренд в зерне и во внутреннем подзапросе
    out = _sub(out,
               "        r.cabinet AS cabinet,\n",
               "        r.cabinet AS cabinet,\n"
               f"        {BRAND_EXPR.replace('brand', 'r.brand')} AS brand_key,\n", 1)
    out = _sub(out,
               "        SELECT\n            cabinet,\n            sale_date,\n            supplier_article,",
               "        SELECT\n            cabinet,\n            brand,\n            sale_date,\n            supplier_article,", 1)
    out = _sub(out, "GROUP BY cabinet, month, sku", "GROUP BY cabinet, month, sku, brand_key", 2)
    # финальный SELECT и ключ джойна
    out = _sub(out,
               "SELECT\n    cabinet                                               AS cabinet,\n",
               "SELECT\n    cabinet                                               AS cabinet,\n"
               "    brand_key                                              AS brand,\n", 1)
    out = _sub(out,
               "ON base.cabinet = c.cabinet AND base.month = c.month AND base.sku = c.sku",
               "ON base.cabinet = c.cabinet AND base.month = c.month AND base.sku = c.sku\n"
               "   AND base.brand_key = c.brand_key", 1)
    out = _sub(out, "ORDER BY cabinet, sku, month;", "ORDER BY cabinet, brand, sku, month;", 1)
    out = _sub(out, "wb_metrics_by_sku_month", "wb_metrics_by_sku_brand_month", out.count("wb_metrics_by_sku_month"))
    return out


def brand_cab(text: str) -> str:
    """Каноническая кабинетная вьюха → бренд-вариант (читает бренд-sku-вьюху)."""
    out = text
    out = _sub(out, "    cabinet                          AS cabinet,\n",
               "    cabinet                          AS cabinet,\n"
               "    brand                             AS brand,\n", 1)
    out = _sub(out, "GROUP BY cabinet, month", "GROUP BY cabinet, brand, month", 1)
    out = _sub(out, "ORDER BY cabinet, month;", "ORDER BY cabinet, brand, month;", 1)
    out = _sub(out, "wb_metrics_by_sku_month", "wb_metrics_by_sku_brand_month", out.count("wb_metrics_by_sku_month"))
    out = _sub(out, "wb_metrics_by_cabinet_month", "wb_metrics_by_cabinet_brand_month",
               out.count("wb_metrics_by_cabinet_month"))
    return out


def to_api(text: str) -> str:
    out = text.replace("FROM wb_reports", f"FROM {API_SOURCE_TABLE}")
    for name in ("wb_metrics_by_sku_brand_month", "wb_metrics_by_cabinet_brand_month"):
        out = out.replace(name, f"{name}_api")
    return out.replace("wb_cogs_weekly_api", "wb_cogs_weekly")


def brand_comments(suffix: str) -> str:
    s, c = f"wb_metrics_by_sku_brand_month{suffix}", f"wb_metrics_by_cabinet_brand_month{suffix}"
    txt = ("Бренд строки отчёта (brand), как есть; пустой бренд — 'Без бренда', без перераспределения по "
           "артикулу. Один артикул может встречаться под несколькими брендами (бренд берётся из строки, а "
           "не из справочника).")
    return (f"\nALTER TABLE {s} COMMENT COLUMN brand '{txt}';\n"
            f"ALTER TABLE {c} COMMENT COLUMN brand '{txt}';\n")


def build() -> str:
    sku_body = CANON_SKU.read_text(encoding="utf-8")
    cab_body = CANON_CAB.read_text(encoding="utf-8")
    for name, body in ((CANON_SKU.name, sku_body), (CANON_CAB.name, cab_body)):
        if "CREATE VIEW" not in body:
            raise SystemExit(f"в {name} не найден CREATE VIEW")
    sku_body = sku_body[sku_body.find("CREATE VIEW"):]
    cab_body = cab_body[cab_body.find("CREATE VIEW"):]
    if "FROM wb_reports" not in sku_body:
        raise SystemExit("в sku-файле нет FROM wb_reports — формула переехала, генератор устарел")

    sku_x, cab_x = brand_sku(sku_body), brand_cab(cab_body)
    parts = [HEADER,
             f"\n-- ==== .xlsx: из {CANON_SKU.name} ====\n", sku_x,
             f"\n-- ==== .xlsx: из {CANON_CAB.name} ====\n", cab_x, brand_comments(""),
             f"\n-- ==== API: из {CANON_SKU.name} ====\n", to_api(sku_x),
             f"\n-- ==== API: из {CANON_CAB.name} ====\n", to_api(cab_x), brand_comments("_api")]
    return "".join(parts)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--check", action="store_true",
                   help="не писать файл, а проверить что он совпадает с генерируемым")
    args = p.parse_args()

    generated = build()
    if args.check:
        if not OUT.exists():
            print(f"НЕТ ФАЙЛА {OUT.relative_to(REPO)} — прогоните генератор", file=sys.stderr)
            sys.exit(1)
        if OUT.read_text(encoding="utf-8") != generated:
            print(f"{OUT.relative_to(REPO)} отстал от канонической формулы — "
                  f"прогоните scripts/gen_wb_metrics_brand_views.py", file=sys.stderr)
            sys.exit(1)
        print("ок: сгенерированный файл совпадает с канонической формулой")
        return

    OUT.write_text(generated, encoding="utf-8")
    print(f"записано: {OUT.relative_to(REPO)} ({len(generated)} символов)")


if __name__ == "__main__":
    main()
