"""Загрузка данных Google-Таблиц Реальта в ClickHouse.

realt_payroll — вкладка «Импорт ФОТ»: тянется напрямую через Google Sheets
API (сервис-аккаунт), не через ручную выгрузку файла. Берутся только
строки-данные (Роль начинается с «ФОТ»); заголовки секций/итоги отсекаются.
Числа в русском формате (неразрывный пробел + запятая) нормализуются в float.
Нераспознанные столбцы уходят в extra_columns. См. schema_realt_gsheets.sql.

Контракт ingest_payroll — как klientiks_core.ingest_files (project_id и
database аргументами, log-колбэк, исключения вместо sys.exit, summary-dict),
но источник — API, а не список файлов.

ingest_expenses (расходы по статьям) — отдельная будущая задача, пока заглушка.
"""

from __future__ import annotations

import os
from datetime import datetime
from pathlib import Path

import clickhouse_connect

SCRIPT_DIR = Path(__file__).parent

SHEETS_SCOPE = ["https://www.googleapis.com/auth/spreadsheets.readonly"]
PAYROLL_SHEET_NAME = "Импорт ФОТ"
PAYROLL_SOURCE = "gsheet:Импорт ФОТ"

COLUMNS = [
    "project_id", "period", "employee_id", "department", "role", "category",
    "pay_type", "salary", "accrued_total", "to_pay", "ndfl", "contributions",
    "revenue", "fot_revenue_share", "comment", "extra_columns", "row_num",
    "source_file",
]

# Позиции колонок во вкладке «Импорт ФОТ» (0-based)
_POS = {
    "period": 0, "employee_id": 1, "department": 2, "role": 3, "category": 4,
    "pay_type": 5, "salary": 7, "revenue": 22, "accrued_total": 31,
    "fot_revenue_share": 32, "ndfl": 33, "contributions": 34, "to_pay": 36,
    "comment": 37,
}
_NUM_FIELDS = {"salary", "revenue", "accrued_total", "ndfl", "contributions", "to_pay"}
# заголовки, попадающие в канонические поля — не дублируем их в extra_columns
_CANON_POS = set(_POS.values())


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


def _pct(value: str):
    """'22,97%' → 22.97 (в процентах). '-'/'' → None."""
    return _num((value or "").replace("%", ""))


def _date(value: str):
    value = (value or "").strip()
    try:
        return datetime.strptime(value, "%d.%m.%Y").date()
    except ValueError:
        return None


def get_sheets_service():
    """Google Sheets API через сервис-аккаунт (ключ из GSHEETS_SA_KEY).

    Путь к ключу — относительный к корню репозитория или абсолютный.
    Ключ (secrets/gsheets-sa.json) в git не коммитится, на сервере — секрет.
    """
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


def parse_payroll(values: list[list[str]]) -> tuple[list[dict], int]:
    """Строки вкладки «Импорт ФОТ» → записи. Возвращает (строки, пропущено).

    Строка считается данными, только если Роль начинается с «ФОТ» — так
    отсекаются шапки секций, итоги и пустые строки. row_num — позиция строки
    во вкладке (1-based, включая заголовок), стабильна для дедупа при перезаливке.
    """
    header = values[0] if values else []
    rows, skipped = [], 0
    for row_num, raw in enumerate(values[1:], start=2):
        role = _cell(raw, _POS["role"])
        if not role.startswith("ФОТ"):
            skipped += 1
            continue

        rec = {"row_num": row_num, "source_file": PAYROLL_SOURCE}
        rec["period"] = _date(_cell(raw, _POS["period"]))
        rec["employee_id"] = _cell(raw, _POS["employee_id"])
        rec["department"] = _cell(raw, _POS["department"]) or None
        rec["role"] = role
        rec["category"] = _cell(raw, _POS["category"]) or None
        rec["pay_type"] = _cell(raw, _POS["pay_type"]) or None
        for f in _NUM_FIELDS:
            rec[f] = _num(_cell(raw, _POS[f]))
        rec["fot_revenue_share"] = _pct(_cell(raw, _POS["fot_revenue_share"]))
        rec["comment"] = _cell(raw, _POS["comment"]) or None

        extra = {}
        for i, cell in enumerate(raw):
            cell = cell.strip()
            if not cell or i in _CANON_POS:
                continue
            name = header[i].strip() if i < len(header) and header[i].strip() else f"col_{i}"
            extra[name] = cell
        rec["extra_columns"] = extra
        rows.append(rec)

    return rows, skipped


def get_client(database: str | None = None):
    host = os.environ["CLICKHOUSE_HOST"]
    port = int(os.environ.get("CLICKHOUSE_PORT", "8443"))
    user = os.environ.get("CLICKHOUSE_USER", "default")
    password = os.environ["CLICKHOUSE_PASSWORD"]
    if database is None:
        database = os.environ.get("CLICKHOUSE_DATABASE", "default")
    secure = os.environ.get("CLICKHOUSE_SECURE", "1") != "0"
    return clickhouse_connect.get_client(
        host=host, port=port, username=user, password=password,
        database=database, secure=secure,
    )


def ingest_payroll(project_id: int, log=print, database: str | None = None,
                   spreadsheet_id: str | None = None, sheet_name: str = PAYROLL_SHEET_NAME) -> dict:
    """Тянет вкладку «Импорт ФОТ» через Google Sheets API и пишет в realt_payroll.

    spreadsheet_id — по умолчанию из GSHEETS_SPREADSHEET_ID. При пустом
    результате — ValueError (никаких sys.exit). PII не логируется.
    """
    if spreadsheet_id is None:
        spreadsheet_id = os.environ["GSHEETS_SPREADSHEET_ID"]

    log(f"  Читаю вкладку «{sheet_name}» из Google Sheets…")
    values = read_tab(spreadsheet_id, sheet_name)
    rows, skipped = parse_payroll(values)
    if skipped:
        log(f"    Пропущено строк не-ФОТ (заголовки/итоги/пустые): {skipped}")
    if not rows:
        raise ValueError("Не найдено ни одной строки ФОТ во вкладке")

    for row in rows:
        row["project_id"] = project_id

    client = get_client(database=database)
    data = [[row.get(col) for col in COLUMNS] for row in rows]
    client.insert("realt_payroll", data, column_names=COLUMNS)
    log(f"Загружено {len(data)} строк в realt_payroll.")

    return {"rows": len(data), "skipped": skipped}


def ingest_expenses(paths: list[Path], project_id: int, log=print, database: str | None = None) -> dict:
    """Расходы по статьям — отдельная будущая задача, формат ещё не согласован."""
    raise NotImplementedError
