#!/usr/bin/env python3
"""
Генерирует API-вариант вьюх метрик WB из КАНОНИЧЕСКИХ файлов.

Зачем генератор, а не вторая копия формулы руками: формула метрик WB должна
жить в одном месте. Вторая копия неизбежно отстаёт — проект это уже проходил
(архивная Модель 57 осталась на старой формуле лояльности и тихо расходилась
с боевой, см. заголовок schema_wb_metrics_views_sku.sql).

Разница между «метрики из .xlsx» и «метрики из API» сведена к ОДНОЙ строке —
имени таблицы в FROM. Имена колонок выравнивает вьюха-переименователь
wb_api_realization_as_reports (schema_wb_api_as_reports.sql).

Сгенерированный файл КОММИТИТСЯ в репозиторий (чтобы схему можно было
накатить без запуска Python), а tests/test_wb_metrics_api_view.py проверяет,
что он совпадает с тем, что генератор выдаёт из текущего канонического файла.
Поправили формулу — прогоните генератор, иначе тест упадёт.

Запуск:
    python3 scripts/gen_wb_metrics_api_view.py          # записать файл
    python3 scripts/gen_wb_metrics_api_view.py --check  # только проверить
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SRC = REPO / "src"

CANON_SKU = SRC / "schema_wb_metrics_views_sku.sql"
CANON_CAB = SRC / "schema_wb_metrics_views.sql"
OUT = SRC / "schema_wb_metrics_views_api.sql"

SOURCE_TABLE = "wb_api_realization_as_reports"

HEADER = f"""-- СГЕНЕРИРОВАННЫЙ ФАЙЛ. Не правьте руками.
--
-- Источник: {CANON_SKU.name} + {CANON_CAB.name}
-- Генератор: scripts/gen_wb_metrics_api_view.py
--
-- Это те же метрики WB, что в канонических вьюхах, но посчитанные на данных
-- ФИНАНСОВОГО API (wb_api_realization) вместо ручной выгрузки .xlsx
-- (wb_reports). Формула НЕ переписана — она взята из канонического файла
-- дословно, заменено только имя таблицы в FROM на {SOURCE_TABLE}
-- (вьюха-переименователь, см. schema_wb_api_as_reports.sql) и добавлен
-- суффикс _api к именам вьюх.
--
-- Правите формулу — правьте КАНОНИЧЕСКИЙ файл и прогоняйте генератор.
-- tests/test_wb_metrics_api_view.py проверяет, что этот файл не отстал.
--
-- Назначение: сверка «API против .xlsx» на одних и тех же формулах и
-- переключение потребителей (Модель 49, отчёт для адаптера) на API, когда
-- сверка сойдётся. Прямой аналог ozon_metrics_by_cabinet_month_api.
"""


def transform(text: str) -> tuple[str, int]:
    """Каноническая формула → её API-вариант. Возвращает (sql, сколько раз
    заменён источник данных).

    Замены строго механические и проверяемые: имя исходной таблицы и имена
    самих вьюх. Тела агрегатов не трогаются вообще.

    Заменять источник нужно НЕ в каждом файле: кабинетная вьюха читает не
    wb_reports, а sku-вьюху (она тонкая агрегация поверх неё), и там сработает
    только переименование вьюх ниже. Поэтому счётчик возвращается наружу и
    проверяется по обоим файлам сразу.
    """
    out = text
    n_from = out.count("FROM wb_reports")
    out = out.replace("FROM wb_reports", f"FROM {SOURCE_TABLE}")

    # 2) имена вьюх: и определения, и ссылки друг на друга, и COMMENT COLUMN
    for name in ("wb_metrics_by_sku_month", "wb_metrics_by_cabinet_month"):
        out = out.replace(name, f"{name}_api")

    # 3) справочник себестоимости общий, суффикс ему не нужен
    out = out.replace("wb_cogs_weekly_api", "wb_cogs_weekly")

    return out, n_from


def build() -> str:
    parts = [HEADER]
    total_from = 0
    for path in (CANON_SKU, CANON_CAB):
        body = path.read_text(encoding="utf-8")
        # комментарии-заголовки канонических файлов не тащим: они описывают
        # .xlsx-вариант и в сгенерированном файле только путали бы
        idx = body.find("CREATE VIEW")
        if idx < 0:
            raise SystemExit(f"в {path.name} не найден CREATE VIEW")
        sql, n_from = transform(body[idx:])
        total_from += n_from
        parts.append(f"\n-- ==== из {path.name} ====\n")
        parts.append(sql)
    if total_from == 0:
        raise SystemExit(
            "ни в одном каноническом файле не найдено FROM wb_reports — "
            "формула переехала, генератор устарел")
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
        current = OUT.read_text(encoding="utf-8")
        if current != generated:
            print(f"{OUT.relative_to(REPO)} отстал от канонической формулы — "
                  f"прогоните scripts/gen_wb_metrics_api_view.py", file=sys.stderr)
            sys.exit(1)
        print("ок: сгенерированный файл совпадает с канонической формулой")
        return

    OUT.write_text(generated, encoding="utf-8")
    print(f"записано: {OUT.relative_to(REPO)} ({len(generated)} символов)")


if __name__ == "__main__":
    main()
