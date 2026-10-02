"""Загрузка Google-Таблицы «Продвижение CS» (CloudSix) в ClickHouse.

Три вкладки одной таблицы (ID 1OnKgJGrtfX4NaGh6ySw4O_dm6S83aKFJ2ukMzYcwD7I):

«Продв WB» — построчно по кампании, посуточно. Тех. столбец I «Артикул» —
уже готовый результат ВПР по справочнику (вкладка «Справочник», блок
«Для WB», столбцы A/B), который ведётся вручную: когда появляется новая
кампания, маркетолог вынимает артикул из её имени и прописывает в
справочник, иначе ВПР не находит соответствие.

«Продв Ozon» — построчно по SKU+кампании, за весь месяц (у Ozon нет
посуточной выгрузки продвижения). Тех. столбец U «Дата» проставляется
вручную 1-м числом месяца отчёта — просто чтобы иметь хоть помесячный
разрез. Тех. столбец V «Артикул» — ВПР по справочнику (блок «Для Ozon»,
столбцы D/E), который заполняется из SKU финотчётов Ozon.

«Справочник» — два независимых блока в одной вкладке, разделённых пустым
столбцом C: слева (A/B) Кампания→Артикул для WB, справа (D/E) SKU→Артикул
для Ozon. Оба ведутся вручную, независимой длины.

Контракт как у realt_gsheets_core.py: project_id/database аргументами,
log-колбэк, ValueError вместо sys.exit, summary-dict {rows, skipped}.
row_num — 1-based позиция строки во вкладке, ключ дедупа при перезаливке
(ReplacingMergeTree). См. src/schema_promotion.sql.
"""

from __future__ import annotations

import os
from datetime import date, datetime
from pathlib import Path

import ch_connect

SCRIPT_DIR = Path(__file__).parent

SHEETS_SCOPE = ["https://www.googleapis.com/auth/spreadsheets.readonly"]

WB_PROMOTION_SHEET_NAME = "Продв WB"
WB_PROMOTION_SOURCE = "gsheet:Продв WB"
WB_PROMOTION_COLUMNS = [
    "project_id", "campaign_id", "campaign", "section", "promo_date",
    "write_off_source", "amount", "document_number", "article", "row_num",
    "source_file",
]
# Позиции колонок во вкладке «Продв WB» (0-based)
_WB_POS = {
    "campaign_id": 0, "campaign": 1, "section": 2, "promo_date": 3,
    "write_off_source": 4, "amount": 5, "document_number": 6, "article": 8,
}


def _cell(row: list, idx: int) -> str:
    return row[idx].strip() if idx < len(row) else ""


def _num(value: str):
    """'120 000,00' / '134\\xa0400' / '-2 617,00' / '-' → float | None."""
    value = (value or "").replace("\xa0", "").replace(" ", "").replace(",", ".").strip()
    if not value or value == "-":
        return None
    try:
        return float(value)
    except ValueError:
        return None


def _date(value: str):
    value = (value or "").strip()
    try:
        return datetime.strptime(value, "%d.%m.%Y").date()
    except ValueError:
        return None


def parse_wb_promotion(values: list[list[str]]) -> tuple[list[dict], int]:
    """Вкладка «Продв WB» → записи. Возвращает (строки, пропущено).

    Строка — данные, только если заполнена «Кампания» (столбец B); иначе
    (пустая/декоративная строка) — пропуск. row_num — 1-based позиция строки
    во вкладке (включая заголовок), ключ дедупа при перезаливке.
    """
    rows, skipped = [], 0
    for row_num, raw in enumerate(values[1:], start=2):
        campaign = _cell(raw, _WB_POS["campaign"])
        if not campaign:
            skipped += 1
            continue

        rec = {"row_num": row_num, "source_file": WB_PROMOTION_SOURCE, "campaign": campaign}
        rec["campaign_id"] = _cell(raw, _WB_POS["campaign_id"]) or None
        rec["section"] = _cell(raw, _WB_POS["section"]) or None
        rec["promo_date"] = _date(_cell(raw, _WB_POS["promo_date"]))
        rec["write_off_source"] = _cell(raw, _WB_POS["write_off_source"]) or None
        rec["amount"] = _num(_cell(raw, _WB_POS["amount"]))
        rec["document_number"] = _cell(raw, _WB_POS["document_number"]) or None
        rec["article"] = _cell(raw, _WB_POS["article"]) or None
        rows.append(rec)

    return rows, skipped


OZON_PROMOTION_SHEET_NAME = "Продв Ozon"
OZON_PROMOTION_SOURCE = "gsheet:Продв Ozon"
OZON_PROMOTION_COLUMNS = [
    "project_id", "sku", "product_name", "tool", "placement", "campaign_id",
    "spend_rub", "drr_in_promotion_pct", "sales_in_promotion_rub", "items_sold",
    "sales_in_promotion_model_rub", "items_sold_model", "ctr_pct", "impressions",
    "clicks", "cart_adds", "cart_conversion_pct", "drr_pct", "cost_per_order_rub",
    "avg_click_cost_rub", "promo_date", "article", "row_num", "source_file",
]
# Позиции колонок во вкладке «Продв Ozon» (0-based; 19 — пустая разделительная)
_OZON_POS = {
    "sku": 0, "product_name": 1, "tool": 2, "placement": 3, "campaign_id": 4,
    "spend_rub": 5, "drr_in_promotion_pct": 6, "sales_in_promotion_rub": 7,
    "items_sold": 8, "sales_in_promotion_model_rub": 9, "items_sold_model": 10,
    "ctr_pct": 11, "impressions": 12, "clicks": 13, "cart_adds": 14,
    "cart_conversion_pct": 15, "drr_pct": 16, "cost_per_order_rub": 17,
    "avg_click_cost_rub": 18, "promo_date": 20, "article": 21,
}
_OZON_STR_FIELDS = {"sku", "product_name", "tool", "placement", "campaign_id", "article"}
_OZON_NUM_FIELDS = {
    "spend_rub", "drr_in_promotion_pct", "sales_in_promotion_rub", "items_sold",
    "sales_in_promotion_model_rub", "items_sold_model", "ctr_pct", "impressions",
    "clicks", "cart_adds", "cart_conversion_pct", "drr_pct", "cost_per_order_rub",
    "avg_click_cost_rub",
}


def parse_ozon_promotion(values: list[list[str]]) -> tuple[list[dict], int]:
    """Вкладка «Продв Ozon» → записи. Возвращает (строки, пропущено).

    Строка — данные, только если заполнен «SKU» (столбец A); иначе пропуск.
    В отличие от WB здесь нет посуточной даты — promo_date (столбец U, тех.)
    проставляется вручную 1-м числом месяца отчёта.
    """
    rows, skipped = [], 0
    for row_num, raw in enumerate(values[1:], start=2):
        sku = _cell(raw, _OZON_POS["sku"])
        if not sku:
            skipped += 1
            continue

        rec = {"row_num": row_num, "source_file": OZON_PROMOTION_SOURCE, "sku": sku}
        for f in _OZON_STR_FIELDS - {"sku"}:
            rec[f] = _cell(raw, _OZON_POS[f]) or None
        for f in _OZON_NUM_FIELDS:
            rec[f] = _num(_cell(raw, _OZON_POS[f]))
        rec["promo_date"] = _date(_cell(raw, _OZON_POS["promo_date"]))
        rows.append(rec)

    return rows, skipped


REFERENCE_SHEET_NAME = "Справочник"
WB_PROMOTION_REFERENCE_SOURCE = "gsheet:Справочник(WB)"
OZON_PROMOTION_REFERENCE_SOURCE = "gsheet:Справочник(Ozon)"
WB_PROMOTION_REFERENCE_COLUMNS = ["project_id", "campaign", "article", "row_num", "source_file"]
OZON_PROMOTION_REFERENCE_COLUMNS = ["project_id", "sku", "article", "row_num", "source_file"]
# Позиции колонок вкладки «Справочник» (0-based): левый блок «Для WB» (A/B),
# правый блок «Для Ozon» (D/E); столбец C(2) — пустой разделитель. Данные
# начинаются с 3-й строки (index 2) — первые две строки — заголовки блоков.
_REF_WB_POS = {"campaign": 0, "article": 1}
_REF_OZON_POS = {"sku": 3, "article": 4}


def parse_wb_promotion_reference(values: list[list[str]]) -> tuple[list[dict], int]:
    """Левый блок «Справочник» (столбцы A/B, «Для WB») → записи.

    Строка — данные, только если заполнена «Кампания» (столбец A); блок
    короче правого (Ozon) — строки, где он уже закончился, пропускаются.
    """
    rows, skipped = [], 0
    for row_num, raw in enumerate(values[2:], start=3):
        campaign = _cell(raw, _REF_WB_POS["campaign"])
        if not campaign:
            skipped += 1
            continue
        rows.append({
            "row_num": row_num, "source_file": WB_PROMOTION_REFERENCE_SOURCE,
            "campaign": campaign, "article": _cell(raw, _REF_WB_POS["article"]) or None,
        })
    return rows, skipped


def parse_ozon_promotion_reference(values: list[list[str]]) -> tuple[list[dict], int]:
    """Правый блок «Справочник» (столбцы D/E, «Для Ozon») → записи.

    Строка — данные, только если заполнен «SKU» (столбец D).
    """
    rows, skipped = [], 0
    for row_num, raw in enumerate(values[2:], start=3):
        sku = _cell(raw, _REF_OZON_POS["sku"])
        if not sku:
            skipped += 1
            continue
        rows.append({
            "row_num": row_num, "source_file": OZON_PROMOTION_REFERENCE_SOURCE,
            "sku": sku, "article": _cell(raw, _REF_OZON_POS["article"]) or None,
        })
    return rows, skipped


def get_sheets_service():
    """Google Sheets API через сервис-аккаунт (ключ из GSHEETS_SA_KEY) —
    тот же сервис-аккаунт, что уже используется для Реальта, у него уже
    есть доступ к этой таблице (проверено вручную)."""
    from google.oauth2 import service_account
    from googleapiclient.discovery import build

    key_path = Path(os.environ["GSHEETS_SA_KEY"])
    if not key_path.is_absolute():
        key_path = SCRIPT_DIR.parent / key_path
    creds = service_account.Credentials.from_service_account_file(str(key_path), scopes=SHEETS_SCOPE)
    return build("sheets", "v4", credentials=creds, cache_discovery=False)


def read_tab(spreadsheet_id: str, sheet_name: str) -> list[list[str]]:
    svc = get_sheets_service()
    res = svc.spreadsheets().values().get(
        spreadsheetId=spreadsheet_id, range=sheet_name,
    ).execute()
    return res.get("values", [])


def get_client(database: str | None = None):
    host = os.environ["CLICKHOUSE_HOST"]
    port = int(os.environ.get("CLICKHOUSE_PORT", "8443"))
    user = os.environ.get("CLICKHOUSE_USER", "default")
    password = os.environ.get("CLICKHOUSE_PASSWORD", "")
    if database is None:
        database = os.environ.get("CLICKHOUSE_DATABASE", "default")
    secure = os.environ.get("CLICKHOUSE_SECURE", "1") != "0"
    return ch_connect.get_client(
        host=host, port=port, username=user, password=password,
        database=database, secure=secure,
    )


def _ingest(project_id: int, log, database: str | None, spreadsheet_id: str | None,
            sheet_name: str, parse_fn, table: str, columns: list[str], source_label: str) -> dict:
    """Общий каркас ingest_* для всех 4 вкладок «Продвижение CS»."""
    if spreadsheet_id is None:
        spreadsheet_id = os.environ["GSHEETS_SPREADSHEET_ID_CLOUDSIX_PROMOTION"]

    log(f"  Читаю вкладку «{sheet_name}» из Google Sheets…")
    values = read_tab(spreadsheet_id, sheet_name)
    rows, skipped = parse_fn(values)
    if skipped:
        log(f"    Пропущено строк без ключа ({source_label}): {skipped}")
    if not rows:
        raise ValueError(f"Не найдено ни одной строки во вкладке «{sheet_name}» ({source_label})")

    for row in rows:
        row["project_id"] = project_id

    client = get_client(database=database)
    data = [[row.get(col) for col in columns] for row in rows]
    client.insert(table, data, column_names=columns)
    log(f"Загружено {len(data)} строк в {table}.")

    return {"rows": len(data), "skipped": skipped}


def ingest_wb_promotion(project_id: int, log=print, database: str | None = None,
                        spreadsheet_id: str | None = None,
                        sheet_name: str = WB_PROMOTION_SHEET_NAME) -> dict:
    """Тянет вкладку «Продв WB» через Google Sheets API и пишет в wb_promotion."""
    return _ingest(project_id, log, database, spreadsheet_id, sheet_name,
                   parse_wb_promotion, "wb_promotion", WB_PROMOTION_COLUMNS, "кампания")


def ingest_ozon_promotion(project_id: int, log=print, database: str | None = None,
                          spreadsheet_id: str | None = None,
                          sheet_name: str = OZON_PROMOTION_SHEET_NAME) -> dict:
    """Тянет вкладку «Продв Ozon» через Google Sheets API и пишет в ozon_promotion."""
    return _ingest(project_id, log, database, spreadsheet_id, sheet_name,
                   parse_ozon_promotion, "ozon_promotion", OZON_PROMOTION_COLUMNS, "SKU")


def ingest_wb_promotion_reference(project_id: int, log=print, database: str | None = None,
                                  spreadsheet_id: str | None = None,
                                  sheet_name: str = REFERENCE_SHEET_NAME) -> dict:
    """Тянет левый блок «Справочник» (Для WB) и пишет в wb_promotion_reference."""
    return _ingest(project_id, log, database, spreadsheet_id, sheet_name,
                   parse_wb_promotion_reference, "wb_promotion_reference",
                   WB_PROMOTION_REFERENCE_COLUMNS, "кампания")


def ingest_ozon_promotion_reference(project_id: int, log=print, database: str | None = None,
                                    spreadsheet_id: str | None = None,
                                    sheet_name: str = REFERENCE_SHEET_NAME) -> dict:
    """Тянет правый блок «Справочник» (Для Ozon) и пишет в ozon_promotion_reference."""
    return _ingest(project_id, log, database, spreadsheet_id, sheet_name,
                   parse_ozon_promotion_reference, "ozon_promotion_reference",
                   OZON_PROMOTION_REFERENCE_COLUMNS, "SKU")
