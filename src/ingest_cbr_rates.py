#!/usr/bin/env python3
"""
Загрузка курсов ЦБ РФ в ClickHouse (таблица cbr_rates).

Нужна, потому что не все кабинеты рублёвые: NoxLab киргизский, WB отдаёт его
отчёты в сомах (currency='KGS'). Чтобы показатели складывались с остальными
кабинетами, каждую операцию переводим в рубли по курсу ЦБ НА ДЕНЬ ОПЕРАЦИИ —
так же, как это делает внешний адаптер. Подробнее — в шапке
src/schema_cbr_rates.sql.

Источник: https://www.cbr.ru/scripts/XML_dynamic.asp (динамика за период).
Коды валют ЦБ берём из https://www.cbr.ru/scripts/XML_valFull.asp по ISO-коду,
чтобы не зашивать 'R01370' в код руками.

Примеры:
    python3 ingest_cbr_rates.py --currency KGS --date-from 2025-12-01 --date-to 2026-09-28
    python3 ingest_cbr_rates.py --currency KGS --date-from 2026-01-01 --date-to 2026-09-28 --dry-run
"""

from __future__ import annotations

import argparse
import sys
import xml.etree.ElementTree as ET
from datetime import date
from pathlib import Path

import requests
from dotenv_safe import load_dotenv

SCRIPT_DIR = Path(__file__).parent
load_dotenv(SCRIPT_DIR.parent / ".env")

from wb_api_core import get_client  # noqa: E402

VAL_LIST_URL = "https://www.cbr.ru/scripts/XML_valFull.asp"
DYNAMIC_URL = "https://www.cbr.ru/scripts/XML_dynamic.asp"

COLUMNS = ["currency", "rate_date", "cbr_code", "nominal", "value", "rate"]


def resolve_cbr_code(iso: str, log=print) -> str:
    """ISO-код валюты -> внутренний код ЦБ (R01370 для KGS).

    Ищем по справочнику, а не зашиваем константой: код ЦБ — вещь
    непрозрачная, и ошибиться в ней молча проще, чем заметить.
    """
    resp = requests.get(VAL_LIST_URL, timeout=60)
    resp.raise_for_status()
    root = ET.fromstring(resp.content)
    for item in root:
        if (item.findtext("ISO_Char_Code") or "").strip().upper() == iso.upper():
            code = item.get("ID")
            log(f"  {iso} -> код ЦБ {code} ({(item.findtext('Name') or '').strip()}), "
                f"номинал {item.findtext('Nominal')}")
            return code
    raise SystemExit(f"валюта {iso!r} не найдена в справочнике ЦБ {VAL_LIST_URL}")


def fetch_rates(cbr_code: str, iso: str, date_from: date, date_to: date, log=print) -> list[list]:
    params = {
        "date_req1": date_from.strftime("%d/%m/%Y"),
        "date_req2": date_to.strftime("%d/%m/%Y"),
        "VAL_NM_RQ": cbr_code,
    }
    resp = requests.get(DYNAMIC_URL, params=params, timeout=120)
    resp.raise_for_status()
    root = ET.fromstring(resp.content)

    rows = []
    for rec in root:
        d = rec.get("Date")
        nominal = int(rec.findtext("Nominal"))
        # ЦБ отдаёт с запятой как десятичным разделителем
        value = float((rec.findtext("Value") or "0").replace(",", "."))
        if nominal <= 0:
            log(f"  ПРОПУСК {d}: номинал {nominal}")
            continue
        day = date(int(d[6:10]), int(d[3:5]), int(d[0:2]))
        rows.append([iso.upper(), day, cbr_code, nominal, value, value / nominal])
    return rows


def main():
    p = argparse.ArgumentParser(description="Загрузка курсов ЦБ РФ в ClickHouse")
    p.add_argument("--currency", required=True, help="ISO-код, напр. KGS")
    p.add_argument("--date-from", required=True, help="YYYY-MM-DD")
    p.add_argument("--date-to", required=True, help="YYYY-MM-DD")
    p.add_argument("--database", help="БД проекта (по умолчанию CLICKHOUSE_DATABASE)")
    p.add_argument("--dry-run", action="store_true", help="не писать в базу, только показать")
    args = p.parse_args()

    d_from = date.fromisoformat(args.date_from)
    d_to = date.fromisoformat(args.date_to)
    if d_from > d_to:
        print("Ошибка: date-from позже date-to", file=sys.stderr)
        sys.exit(1)

    print(f"ЦБ РФ: {args.currency} за {d_from}..{d_to}")
    code = resolve_cbr_code(args.currency)
    rows = fetch_rates(code, args.currency, d_from, d_to)
    if not rows:
        print("ЦБ не вернул ни одного курса за период — ничего не загружено")
        sys.exit(1)

    rates = [r[5] for r in rows]
    print(f"  получено {len(rows)} значений, {rows[0][1]}..{rows[-1][1]}")
    print(f"  курс за единицу: {min(rates):.4f}..{max(rates):.4f} ₽")
    # ЦБ публикует курс только по рабочим дням — это нормально, потребители
    # берут последний известный ASOF-джойном. Но если дыра великовата,
    # лучше увидеть это сразу.
    span = (rows[-1][1] - rows[0][1]).days + 1
    print(f"  покрытие: {len(rows)} значений на {span} календарных дней "
          f"(остальные — выходные и праздники, берутся по последнему известному)")

    if args.dry_run:
        print("--dry-run: в базу не пишем")
        return

    client = get_client(database=args.database)
    client.insert("cbr_rates", rows, column_names=COLUMNS)
    print(f"Загружено {len(rows)} строк в cbr_rates.")


if __name__ == "__main__":
    main()
