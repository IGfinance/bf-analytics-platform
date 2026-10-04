#!/usr/bin/env python3
"""
Генерирует БРЕНДОВЫЕ вьюхи метрик Ozon для адаптерных отчётов (столбец «Бренд»
после «Кабинета»). Результат — src/schema_ozon_metrics_views_brand.sql.

ГДЕ БЕРЁТСЯ БРЕНД. В отчётах Ozon бренда нет — он в карточке товара (каталог API,
таблица ozon_products, атрибут 85). Сопоставление по артикулу продавца:
offer_id (реализация) = article (.xlsx). Правила бренда те же, что у WB
(scripts/gen_wb_metrics_brand_views.py, brand_expr): пустой бренд и «Нет бренда»
(справочное значение Ozon) → название кабинета; CloudSix везде «Cloud Six»;
бренд, совпадающий с кабинетом без учёта регистра, → написание кабинета.

ЧТО ТОЧНО, ЧТО РАСПРЕДЕЛЕНО (решение владельца 2026-10-04):
  * всё, что Ozon привязал к артикулу, ложится на бренд артикула ТОЧНО;
  * расходы, которые Ozon начисляет на кабинет целиком (cash-flow у API-адаптера;
    строки без артикула у .xlsx), раскладываются по брендам кабинета
    ПРОПОРЦИОНАЛЬНО ВЫРУЧКЕ бренда за месяц. Это оценка, а не данные Ozon.
    Продвижение владелец собирается разбить поартикульно отдельно — тогда эта
    статья перестанет быть оценкой, остальные останутся пропорциональными;
  * доля бренда = max(выручка бренда, 0) / сумма таких по кабинету за месяц
    (бренд с отрицательной нетто-выручкой — возвраты — расходов не получает);
  * нет выручки у кабинета за месяц (или нет реализации) → все расходы на строку
    с названием кабинета, ничего не размазывается.
  * «К перечислению за товар» по брендам берётся из реализации ТОЧНО: на данных
    2026-10-04 она совпадает с cash-flow до рубля по всем кабинет-месяцам.

Формулы метрик НЕ копируются: реализация-по-брендам получается механической
заменой из канонической src/schema_ozon_realization_metrics.sql (как WB), а
.xlsx-вариант собран поверх канонической ozon_metrics_by_sku_month и cash-flow
вьюхи. Канонические вьюхи не меняются.

Вьюхи:
    ozon_product_brands                              кабинет × артикул → бренд
    ozon_realization_by_cabinet_brand_month          кабинет × бренд × месяц (реализация)
    ozon_metrics_by_cabinet_brand_month              то же из .xlsx (адаптер xlsx)
    ozon_metrics_by_cabinet_brand_month_cashflow_api cash-flow, разложенный по брендам

Запуск:
    python3 scripts/gen_ozon_brand_views.py          # записать файл
    python3 scripts/gen_ozon_brand_views.py --check  # только проверить
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SRC = REPO / "src"
sys.path.insert(0, str(Path(__file__).resolve().parent))

from gen_wb_metrics_brand_views import brand_expr, cab_name_expr  # noqa: E402

CANON_REAL = SRC / "schema_ozon_realization_metrics.sql"
OUT = SRC / "schema_ozon_metrics_views_brand.sql"

OZON_BLANKS = ("нет бренда",)

# метрики канонической ozon_metrics_by_sku_month (порядок = порядок колонок)
XLSX_COUNTS = ["sales_qty", "cogs_qty_covered", "cogs_qty_uncovered"]
XLSX_MONEY = ["sales_with_spp", "sales_amount", "spp_amount", "commission", "returns_corrections",
              "payable_for_goods", "logistics_cost", "last_mile_cost", "fines", "surcharges",
              "storage_cost", "promotion_cost", "other_accruals", "payable_total", "cogs", "gross_profit"]
# колонки cash-flow, которые раскладываются по доле (payable_for_goods — точно из реализации,
# payable_total пересобирается)
CF_ALLOC = ["logistics_cost", "last_mile_cost", "fines", "surcharges", "storage_cost",
            "promotion_cost", "other_accruals", "unmapped"]
CF_TOTAL_PARTS = ["logistics_cost", "last_mile_cost", "fines", "surcharges", "storage_cost",
                  "promotion_cost", "other_accruals"]  # без unmapped: как в payable_total cash-flow-вьюхи

HEADER = f"""-- СГЕНЕРИРОВАННЫЙ ФАЙЛ. Не правьте руками.
--
-- Генератор: scripts/gen_ozon_brand_views.py (там же — правила и обоснование).
-- Источник формул: {CANON_REAL.name}, ozon_metrics_by_sku_month,
-- ozon_metrics_by_cabinet_month_cashflow_api. Канонические вьюхи не затронуты.
--
-- Бренд — из каталога Ozon API (ozon_products, атрибут «Бренд»), по артикулу
-- продавца. Всё, что привязано к артикулу, лежит на бренде артикула точно;
-- расходы уровня кабинета раскладываются ПРОПОРЦИОНАЛЬНО ВЫРУЧКЕ бренда за
-- месяц (оценка, не данные Ozon). Пустой бренд и «Нет бренда» = название
-- кабинета, CloudSix = «Cloud Six».
--
-- Порядок накатки: ozon_product_brands → realization → xlsx → cashflow_api.
-- Применять под пользователем с правом DDL (default). Вьюхи новые.
"""


def _sub(text: str, old: str, new: str, expected: int) -> str:
    n = text.count(old)
    if n != expected:
        raise SystemExit(f"генератор устарел: ожидал {expected} вхождений, нашёл {n}:\n{old!r}")
    return text.replace(old, new)


def product_brands() -> str:
    expr = brand_expr("cabinet", "b", OZON_BLANKS)
    return f"""CREATE VIEW IF NOT EXISTS ozon_product_brands AS
SELECT
    cabinet                       AS cabinet,
    offer_key                     AS offer_key,
    {expr} AS brand_key
FROM (
    SELECT cabinet, lowerUTF8(trim(offer_id)) AS offer_key, argMax(brand, loaded_at) AS b
    FROM ozon_products FINAL
    WHERE trim(offer_id) != ''
    GROUP BY cabinet, offer_key
);

ALTER TABLE ozon_product_brands COMMENT COLUMN brand_key 'Бренд артикула по каталогу Ozon: пустой и «Нет бренда» заменены названием кабинета, CloudSix = «Cloud Six». Артикула нет в каталоге — в вьюхах-потребителях тоже название кабинета.';
"""


def realization_brand(text: str) -> str:
    out = text[text.find("CREATE VIEW"):]
    # cogs_agg: бренд артикула в зерне
    out = _sub(out,
               "        cabinet                                  AS cabinet,\n"
               "        toStartOfMonth(stop_date)                AS month,\n",
               "        cabinet                                  AS cabinet,\n"
               "        toStartOfMonth(stop_date)                AS month,\n"
               "        brand_key                                AS brand_key,\n", 1)
    out = _sub(out,
               "            r.stop_date AS stop_date,\n",
               "            r.stop_date AS stop_date,\n"
               f"            coalesce(nullIf(pbr.brand_key, ''), {cab_name_expr('r.cabinet')}) AS brand_key,\n", 1)
    out = _sub(out,
               "          ON lowerUTF8(trim(r.offer_id)) = w.sku AND toMonday(r.stop_date) = w.week_start\n",
               "          ON lowerUTF8(trim(r.offer_id)) = w.sku AND toMonday(r.stop_date) = w.week_start\n"
               "        LEFT JOIN ozon_product_brands AS pbr\n"
               "          ON pbr.cabinet = r.cabinet AND pbr.offer_key = lowerUTF8(trim(r.offer_id))\n", 1)
    out = _sub(out, "    GROUP BY cabinet, month\n)", "    GROUP BY cabinet, month, brand_key\n)", 1)
    # основной SELECT
    o_brand = f"coalesce(nullIf(pbo.brand_key, ''), {cab_name_expr('o.cabinet')})"
    out = _sub(out,
               "    toStartOfMonth(o.stop_date)                                  AS month,\n",
               "    toStartOfMonth(o.stop_date)                                  AS month,\n"
               f"    {o_brand} AS brand,\n", 1)
    out = _sub(out,
               "LEFT JOIN cogs_agg AS c\n"
               "       ON c.cabinet = o.cabinet AND c.month = toStartOfMonth(o.stop_date)\n"
               "GROUP BY o.cabinet, toStartOfMonth(o.stop_date)\n"
               "ORDER BY cabinet, month;",
               "LEFT JOIN ozon_product_brands AS pbo\n"
               "       ON pbo.cabinet = o.cabinet AND pbo.offer_key = lowerUTF8(trim(o.offer_id))\n"
               "LEFT JOIN cogs_agg AS c\n"
               "       ON c.cabinet = o.cabinet AND c.month = toStartOfMonth(o.stop_date)\n"
               f"      AND c.brand_key = {o_brand}\n"
               f"GROUP BY o.cabinet, toStartOfMonth(o.stop_date), {o_brand}\n"
               "ORDER BY cabinet, brand, month;", 1)
    out = _sub(out, "ozon_realization_by_cabinet_month", "ozon_realization_by_cabinet_brand_month",
               out.count("ozon_realization_by_cabinet_month"))
    out += ("\nALTER TABLE ozon_realization_by_cabinet_brand_month COMMENT COLUMN brand 'Бренд по каталогу Ozon "
            "(ozon_product_brands): точно по артикулу; пустой и «Нет бренда» — название кабинета, CloudSix = «Cloud Six».';\n")
    return out


def xlsx_brand() -> str:
    allm = XLSX_COUNTS + XLSX_MONEY
    cols = ",\n           ".join(f"k.{m} AS {m}" for m in allm)
    att_sum = ",\n           ".join(f"sum({m}) AS {m}" for m in allm)
    un_sum = ",\n           ".join(f"sum({m}) AS {m}" for m in XLSX_MONEY)
    row_att = ", ".join(allm)
    # ряды-доли: счётчики 0, деньги — доля от «без артикула»
    zeros = {m: "toInt64(0)" for m in XLSX_COUNTS}
    sel_alloc = ",\n           ".join(
        (f"{zeros[m]} AS {m}" if m in XLSX_COUNTS else f"u.{m} * r.share AS {m}") for m in allm)
    final = ",\n    ".join(
        (f"toInt64(sum({m})) AS {m}" if m in XLSX_COUNTS else f"sum({m}) AS {m}") for m in allm)
    k_brand = f"coalesce(nullIf(pb.brand_key, ''), {cab_name_expr('k.cabinet')})"
    return f"""CREATE VIEW IF NOT EXISTS ozon_metrics_by_cabinet_brand_month AS
WITH s AS (
    -- уровень артикула из КАНОНИЧЕСКОЙ вьюхи; формулы здесь не пересчитываются
    SELECT k.cabinet AS cabinet,
           k.month AS month,
           if(k.sku = 'без артикула', '', {k_brand}) AS brand_key,
           {cols}
    FROM ozon_metrics_by_sku_month AS k
    LEFT JOIN ozon_product_brands AS pb
           ON pb.cabinet = k.cabinet AND pb.offer_key = lowerUTF8(trim(k.sku))
),
att AS (
    -- привязано к артикулу — на бренд артикула ТОЧНО
    SELECT cabinet, month, brand_key,
           {att_sum}
    FROM s
    WHERE brand_key != ''
    GROUP BY cabinet, month, brand_key
),
un AS (
    -- начисления без артикула (Ozon относит их на кабинет целиком) — будут разложены
    SELECT cabinet, month,
           {un_sum}
    FROM s
    WHERE brand_key = ''
    GROUP BY cabinet, month
),
wt AS (
    SELECT cabinet, month, sum(greatest(sales_amount, 0)) AS wsum
    FROM att
    GROUP BY cabinet, month
),
recv AS (
    -- получатели доли: бренды с положительной выручкой пропорционально ей…
    SELECT a.cabinet AS cabinet, a.month AS month, a.brand_key AS brand_key,
           greatest(a.sales_amount, 0) / t.wsum AS share
    FROM att AS a
    INNER JOIN wt AS t ON t.cabinet = a.cabinet AND t.month = a.month
    WHERE t.wsum > 0
    UNION ALL
    -- …а если выручки нет — всё на строку с названием кабинета
    SELECT u.cabinet AS cabinet, u.month AS month, {cab_name_expr('u.cabinet')} AS brand_key,
           toFloat64(1) AS share
    FROM un AS u
    LEFT JOIN wt AS t ON t.cabinet = u.cabinet AND t.month = u.month
    WHERE coalesce(t.wsum, 0) = 0
),
all_rows AS (
    SELECT cabinet, month, brand_key, {row_att} FROM att
    UNION ALL
    SELECT r.cabinet AS cabinet, r.month AS month, r.brand_key AS brand_key,
           {sel_alloc}
    FROM recv AS r
    INNER JOIN un AS u ON u.cabinet = r.cabinet AND u.month = r.month
)
SELECT
    cabinet                  AS cabinet,
    month                    AS month,
    brand_key                AS brand,
    {final}
FROM all_rows
GROUP BY cabinet, month, brand_key
ORDER BY cabinet, brand, month;

ALTER TABLE ozon_metrics_by_cabinet_brand_month COMMENT COLUMN brand 'Бренд по каталогу Ozon (ozon_product_brands). Начисления с артикулом — на бренд артикула точно; начисления без артикула (расходы кабинета) разложены по брендам пропорционально выручке бренда за месяц (оценка). Пустой и «Нет бренда» — название кабинета, CloudSix = «Cloud Six».';
"""


def cashflow_brand() -> str:
    # Сырые колонки cash-flow названы raw_*: в ClickHouse псевдоним с именем колонки
    # перекрывает её во всех выражениях того же SELECT, и payable_total считался бы
    # от УЖЕ умноженных на долю значений (расходы × доля²) — так и вышло в первой версии.
    c_cols = ",\n           ".join(f"c.{m} AS raw_{m}" for m in CF_ALLOC)
    parts = " + ".join(f"raw_{m}" for m in CF_TOTAL_PARTS)
    out_alloc = ",\n    ".join(f"raw_{m} * share AS {m}" for m in CF_ALLOC)
    return f"""CREATE VIEW IF NOT EXISTS ozon_metrics_by_cabinet_brand_month_cashflow_api AS
WITH rb AS (
    SELECT cabinet, month, brand, sales_amount, payable_for_goods
    FROM ozon_realization_by_cabinet_brand_month
),
wt AS (
    SELECT cabinet, month, sum(greatest(sales_amount, 0)) AS wsum
    FROM rb
    GROUP BY cabinet, month
),
parts AS (
    -- есть реализация с выручкой: «К перечислению за товар» точно из реализации (она
    -- совпадает с cash-flow до рубля), расходы кабинета — по доле выручки бренда
    SELECT c.cabinet AS cabinet, c.month AS month, rb.brand AS brand,
           rb.payable_for_goods AS pfg,
           greatest(rb.sales_amount, 0) / wt.wsum AS share,
           {c_cols}
    FROM ozon_metrics_by_cabinet_month_cashflow_api AS c
    INNER JOIN rb ON rb.cabinet = c.cabinet AND rb.month = c.month
    INNER JOIN wt ON wt.cabinet = c.cabinet AND wt.month = c.month
    WHERE wt.wsum > 0
    UNION ALL
    -- реализации (или выручки) нет — делить не по чему, всё на название кабинета
    SELECT c.cabinet AS cabinet, c.month AS month, {cab_name_expr('c.cabinet')} AS brand,
           c.payable_for_goods AS pfg,
           toFloat64(1) AS share,
           {c_cols}
    FROM ozon_metrics_by_cabinet_month_cashflow_api AS c
    LEFT JOIN wt ON wt.cabinet = c.cabinet AND wt.month = c.month
    WHERE coalesce(wt.wsum, 0) = 0
)
SELECT
    cabinet                  AS cabinet,
    month                    AS month,
    brand                    AS brand,
    pfg                      AS payable_for_goods,
    share                    AS share,
    {out_alloc},
    pfg + ({parts}) * share AS payable_total
FROM parts
ORDER BY cabinet, brand, month;

ALTER TABLE ozon_metrics_by_cabinet_brand_month_cashflow_api COMMENT COLUMN share 'Доля бренда в расходах кабинета за месяц = max(выручка бренда, 0) / сумма таких по кабинету; 1, если реализации или выручки нет. Нужна детальному адаптеру, чтобы раскладывать отдельные статьи cash-flow тем же способом.';
ALTER TABLE ozon_metrics_by_cabinet_brand_month_cashflow_api COMMENT COLUMN brand 'Бренд по каталогу Ozon. «К перечислению за товар» — точно из реализации по бренду; логистика, последняя миля, штрафы, доплаты, хранение, продвижение, прочие начисления и нераспознанное — расходы кабинета, разложенные пропорционально выручке бренда за месяц (оценка; продвижение планируется перевести на поартикульные данные). Нет реализации — всё на название кабинета.';
"""


def build() -> str:
    canon = CANON_REAL.read_text(encoding="utf-8")
    if "CREATE VIEW" not in canon:
        raise SystemExit(f"в {CANON_REAL.name} не найден CREATE VIEW")
    return "".join([
        HEADER,
        "\n-- ==== справочник: кабинет × артикул → бренд ====\n", product_brands(),
        f"\n-- ==== реализация по брендам: из {CANON_REAL.name} ====\n", realization_brand(canon),
        "\n-- ==== .xlsx: поверх ozon_metrics_by_sku_month ====\n", xlsx_brand(),
        "\n-- ==== API: cash-flow, разложенный по брендам ====\n", cashflow_brand(),
    ])


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
                  f"прогоните scripts/gen_ozon_brand_views.py", file=sys.stderr)
            sys.exit(1)
        print("ок: сгенерированный файл совпадает с канонической формулой")
        return
    OUT.write_text(generated, encoding="utf-8")
    print(f"записано: {OUT.relative_to(REPO)} ({len(generated)} символов)")


if __name__ == "__main__":
    main()
