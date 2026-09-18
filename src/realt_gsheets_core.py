"""Загрузка данных Google-Таблиц Реальта в ClickHouse.

realt_payroll — вкладка «Импорт ФОТ»: тянется напрямую через Google Sheets
API (сервис-аккаунт), не через ручную выгрузку файла. Берутся только
строки-данные (Роль начинается с «ФОТ»); заголовки секций/итоги отсекаются.
Числа в русском формате (неразрывный пробел + запятая) нормализуются в float.
Нераспознанные столбцы уходят в extra_columns. См. schema_realt_gsheets.sql.

Контракт ingest_payroll — как klientiks_core.ingest_files (project_id и
database аргументами, log-колбэк, исключения вместо sys.exit, summary-dict),
но источник — API, а не список файлов.

realt_expenses — вкладка «Остальные расходы»: матрица (колонка = статья с двумя
шапками «Статья»/«Дата/Тип», строка = месяц). parse_expenses разворачивает её в
длинные записи (месяц × статья) с типом-группой и флагом is_shaa (Шмилович).

realt_bank_account / realt_cash / realt_accruals — вкладки «Расчетный счет»,
«Наличные», «Начисления» (выгрузка из учётной системы клиента, плоские
регистры движений денег и начислений). Строки уже плоские (не матрица),
парсинг — позиционный по колонкам, строка считается данными, если у неё есть
«Сумма» (иначе это декоративная/пустая строка в конце вкладки).

realt_service_categories — вкладка «Категорирование услуг»: справочник
услуга → категории (тип врача, продолжительность, тип/формат/периодичность
услуги, квалификация врача — джун/мидл/синьор/топ). Ключ — точное название
услуги (совпадает с klientiks_operations.service). Без дублей, 246 строк.

realt_employees — вкладка «Справочник сотрудников»: employee_id (сокращённый
код, как в realt_payroll.employee_id, напр. «АрсТБ_ТД») → ФИО. Без дублей,
84 строки. Связывает ФОТ (payroll, по коду) с визитами (klientiks, по ФИО).
"""

from __future__ import annotations

import os
from datetime import date, datetime
from pathlib import Path

import clickhouse_connect

SCRIPT_DIR = Path(__file__).parent

SHEETS_SCOPE = ["https://www.googleapis.com/auth/spreadsheets.readonly"]
PAYROLL_SHEET_NAME = "Импорт ФОТ"
PAYROLL_SOURCE = "gsheet:Импорт ФОТ"

EXPENSES_SHEET_NAME = "Остальные расходы"
EXPENSES_SOURCE = "gsheet:Остальные расходы"
EXPENSES_COLUMNS = [
    "project_id", "period", "article", "expense_type", "amount", "is_shaa",
    "row_num", "col_num", "source_file",
]

BANK_ACCOUNT_SHEET_NAME = "Расчетный счет"
BANK_ACCOUNT_SOURCE = "gsheet:Расчетный счет"
BANK_ACCOUNT_COLUMNS = [
    "project_id", "account_label", "account_number", "operation_date", "amount",
    "amount_signed", "counterparty", "counterparty_inn", "counterparty_account",
    "purpose", "cf_subarticle", "project", "tag", "pl_article", "accrual_date",
    "accrual_amount", "cf_article", "month_seq", "comment", "company_form",
    "row_num", "source_file",
]
# Позиции колонок во вкладке «Расчетный счет» (0-based)
_BANK_POS = {
    "account_label": 0, "account_number": 1, "operation_date": 2, "amount": 3,
    "amount_signed": 4, "counterparty": 5, "counterparty_inn": 6,
    "counterparty_account": 7, "purpose": 8, "cf_subarticle": 9, "project": 10,
    "tag": 11, "pl_article": 12, "accrual_date": 13, "accrual_amount": 14,
    "cf_article": 15, "month_seq": 16, "comment": 17, "company_form": 18,
}

CASH_SHEET_NAME = "Наличные"
CASH_SOURCE = "gsheet:Наличные"
CASH_COLUMNS = [
    "project_id", "operation_date", "account_name", "amount", "purpose",
    "cf_subarticle", "project", "tag", "pl_article", "accrual_date",
    "accrual_amount", "cf_article", "month_seq", "company_form", "row_num",
    "source_file",
]
# Позиции колонок во вкладке «Наличные» (0-based; колонка 0 и 5 — пустые в источнике)
_CASH_POS = {
    "operation_date": 1, "account_name": 2, "amount": 3, "purpose": 4,
    "cf_subarticle": 6, "project": 7, "tag": 8, "pl_article": 9,
    "accrual_date": 10, "accrual_amount": 11, "cf_article": 12, "month_seq": 13,
    "company_form": 14,
}

ACCRUALS_SHEET_NAME = "Начисления"
ACCRUALS_SOURCE = "gsheet:Начисления"
ACCRUALS_COLUMNS = [
    "project_id", "account_name", "operation_date", "amount", "purpose",
    "comment", "cf_subarticle", "tag", "pl_article", "accrual_date",
    "accrual_amount", "cf_article", "row_num", "source_file",
]
# Позиции колонок во вкладке «Начисления» (0-based; колонка 0 и 6 — пустые в источнике).
# В отличие от «Расчетный счет»/«Наличные» здесь нет «Проект» и «Мес».
_ACCRUALS_POS = {
    "account_name": 1, "operation_date": 2, "amount": 3, "purpose": 4,
    "comment": 5, "cf_subarticle": 7, "tag": 8, "pl_article": 9,
    "accrual_date": 10, "accrual_amount": 11, "cf_article": 12,
}

SERVICE_CATEGORIES_SHEET_NAME = "Категорирование услуг"
SERVICE_CATEGORIES_SOURCE = "gsheet:Категорирование услуг"
SERVICE_CATEGORIES_COLUMNS = [
    "project_id", "service", "doctor_type", "duration", "service_kind", "format",
    "periodicity", "qualification", "row_num", "source_file",
]
# Позиции колонок во вкладке «Категорирование услуг» (0-based; 0 и 2 — пустые)
_SERVICE_CAT_POS = {
    "service": 1, "doctor_type": 3, "duration": 4, "service_kind": 5,
    "format": 6, "periodicity": 7, "qualification": 8,
}

EMPLOYEES_SHEET_NAME = "Справочник сотрудников"
EMPLOYEES_SOURCE = "gsheet:Справочник сотрудников"
EMPLOYEES_COLUMNS = ["project_id", "employee_id", "full_name", "row_num", "source_file"]
# Позиции колонок во вкладке «Справочник сотрудников» (0-based; 0 — пустая)
_EMPLOYEES_POS = {"employee_id": 1, "full_name": 2}

# Рус. сокращения месяцев вкладки «Остальные расходы» (по первым 3 буквам,
# после снятия точки). Формы нерегулярны: «мая-25» без точки, «февр.-25» и т.п.
# «мар»→март(3) и «мая»/«май»→май(5) различаются по 3-буквенному префиксу.
_RU_MON = {
    "янв": 1, "фев": 2, "мар": 3, "апр": 4, "мая": 5, "май": 5, "июн": 6,
    "июл": 7, "авг": 8, "сен": 9, "окт": 10, "ноя": 11, "дек": 12,
}

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


def _date_slash(value: str):
    """'05/01/26' → date(2026, 1, 5). '' → None."""
    value = (value or "").strip()
    try:
        return datetime.strptime(value, "%d/%m/%y").date()
    except ValueError:
        return None


def _accrual_date(value: str):
    """'5 янв. 26\\u202f' / '22 авг. 25' → date(год, месяц, день). '-'/'' → None.

    Формат = '<день> <сокр.месяца>[.] <yy>' (узкий неразрывный пробел \\u202f
    в конце снимается). Использует тот же словарь месяцев _RU_MON, что и
    _ru_month (parse_expenses) — там же см. про нерегулярные сокращения.
    """
    value = (value or "").replace(" ", "").replace("\xa0", " ").strip()
    if not value or value == "-":
        return None
    parts = value.split()
    if len(parts) != 3:
        return None
    day_s, mon_s, yy_s = parts
    if not day_s.isdigit() or not yy_s.isdigit():
        return None
    mon = mon_s.strip().rstrip(".").lower()
    m = _RU_MON.get(mon[:3])
    if m is None:
        return None
    year = 2000 + int(yy_s) if len(yy_s) == 2 else int(yy_s)
    try:
        return date(year, m, int(day_s))
    except ValueError:
        return None


def _int(value: str):
    value = (value or "").strip()
    try:
        return int(value)
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


def _ru_month(label: str):
    """'янв.-25' / 'мая-25' / 'сент.-26' → date(год, месяц, 1). Иначе None.

    Метка = <сокр.месяца>[.]-<yy>. Не-месяцы ('Статья', 'Итого', '') → None.
    """
    label = (label or "").strip()
    if "-" not in label:
        return None
    mon, yy = label.rsplit("-", 1)
    mon = mon.strip().rstrip(".").lower()
    yy = yy.strip()
    m = _RU_MON.get(mon[:3])
    if m is None or not yy.isdigit():
        return None
    year = 2000 + int(yy) if len(yy) == 2 else int(yy)
    return date(year, m, 1)


def parse_expenses(values: list[list[str]]) -> tuple[list[dict], int]:
    """Вкладка-матрица «Остальные расходы» → длинные записи (месяц × статья).

    Возвращает (строки, пропущено). Пропущено — число ячеек-статей со значением
    «-»/пусто в строках-месяцах. Блоки распознаются по строке «Статья» (имена
    статей по колонкам ≥2) и следующей строке «Дата/Тип» (группа/тип). Далее
    идут строки-месяцы (метка в колонке [1]). is_shaa=True, если в имени статьи
    есть «ШАА» (расходы Шмиловича). row_num — 1-based позиция строки во вкладке,
    col_num — индекс колонки статьи; вместе стабильны для дедупа при перезаливке.
    """
    rows, skipped = [], 0
    names, types = None, None
    for row_num, raw in enumerate(values, start=1):
        c1 = _cell(raw, 1)
        if c1 == "Статья":
            names, types = raw, None
            continue
        if c1 == "Дата/Тип":
            types = raw
            continue
        month = _ru_month(c1)
        if month is None or names is None:
            continue
        for col in range(2, len(names)):
            article = _cell(names, col)
            if not article:
                continue
            amount = _num(_cell(raw, col))
            if amount is None:
                skipped += 1
                continue
            etype = _cell(types, col) if types else ""
            rows.append({
                "period": month,
                "article": article,
                "expense_type": etype or None,
                "amount": amount,
                "is_shaa": "ШАА" in article,
                "row_num": row_num,
                "col_num": col,
                "source_file": EXPENSES_SOURCE,
            })
    return rows, skipped


def _flat_row(raw: list, pos: dict, row_num: int, source: str, str_fields: set,
              date_fields: set, num_fields: set, amount_field: str = "amount") -> dict | None:
    """Общий каркас разбора плоской (не матричной) строки: строка — данные,
    только если распознаётся её `amount_field` (иначе это пустая/декоративная
    строка в конце вкладки — пропускаем).
    """
    amount_raw = _cell(raw, pos[amount_field])
    amount = _num(amount_raw)
    if amount is None:
        return None

    rec = {"row_num": row_num, "source_file": source}
    for f in str_fields:
        rec[f] = _cell(raw, pos[f]) or None
    for f in date_fields:
        parser = _accrual_date if f == "accrual_date" else _date_slash
        rec[f] = parser(_cell(raw, pos[f]))
    for f in num_fields:
        rec[f] = _num(_cell(raw, pos[f]))
    if "month_seq" in pos:
        rec["month_seq"] = _int(_cell(raw, pos["month_seq"]))
    return rec


def parse_bank_account(values: list[list[str]]) -> tuple[list[dict], int]:
    """Вкладка «Расчетный счет» (плоский регистр движений по р/с) → записи.

    Строка — данные, если у неё есть «Сумма» (col 3); иначе (пустые/декоративные
    строки в конце вкладки, напр. одинокий «-») — пропуск. row_num — 1-based
    позиция во вкладке (включая заголовок), ключ дедупа при перезаливке.
    """
    str_fields = {"account_label", "account_number", "counterparty",
                  "counterparty_inn", "counterparty_account", "purpose",
                  "cf_subarticle", "project", "tag", "pl_article", "cf_article",
                  "comment", "company_form"}
    date_fields = {"operation_date", "accrual_date"}
    num_fields = {"amount", "amount_signed", "accrual_amount"}

    rows, skipped = [], 0
    for row_num, raw in enumerate(values[1:], start=2):
        rec = _flat_row(raw, _BANK_POS, row_num, BANK_ACCOUNT_SOURCE,
                         str_fields, date_fields, num_fields)
        if rec is None:
            skipped += 1
            continue
        rows.append(rec)
    return rows, skipped


def parse_cash(values: list[list[str]]) -> tuple[list[dict], int]:
    """Вкладка «Наличные» (плоский регистр движений наличных/карт) → записи.

    Контракт как у parse_bank_account (строка — данные, если есть «Сумма»).
    """
    str_fields = {"account_name", "purpose", "cf_subarticle", "project", "tag",
                  "pl_article", "cf_article", "company_form"}
    date_fields = {"operation_date", "accrual_date"}
    num_fields = {"amount", "accrual_amount"}

    rows, skipped = [], 0
    for row_num, raw in enumerate(values[1:], start=2):
        rec = _flat_row(raw, _CASH_POS, row_num, CASH_SOURCE,
                         str_fields, date_fields, num_fields)
        if rec is None:
            skipped += 1
            continue
        rows.append(rec)
    return rows, skipped


def parse_accruals(values: list[list[str]]) -> tuple[list[dict], int]:
    """Вкладка «Начисления» (регистр по методу начисления, без «Проект»/«Мес»,
    в отличие от «Расчетный счет»/«Наличные») → записи. Контракт как у
    parse_bank_account.
    """
    str_fields = {"account_name", "purpose", "comment", "cf_subarticle", "tag",
                  "pl_article", "cf_article"}
    date_fields = {"operation_date", "accrual_date"}
    num_fields = {"amount", "accrual_amount"}

    rows, skipped = [], 0
    for row_num, raw in enumerate(values[1:], start=2):
        rec = _flat_row(raw, _ACCRUALS_POS, row_num, ACCRUALS_SOURCE,
                         str_fields, date_fields, num_fields)
        if rec is None:
            skipped += 1
            continue
        rows.append(rec)
    return rows, skipped


def parse_service_categories(values: list[list[str]]) -> tuple[list[dict], int]:
    """Вкладка «Категорирование услуг» (справочник услуга → категории) → записи.

    Строка — данные, если есть «Название услуги» (col 1); иначе пропуск.
    Без дедупа по имени — на момент написания дублей в справочнике нет,
    но row_num остаётся ключом дедупа при перезаливке (ReplacingMergeTree).
    """
    rows, skipped = [], 0
    for row_num, raw in enumerate(values[1:], start=2):
        service = _cell(raw, _SERVICE_CAT_POS["service"])
        if not service:
            skipped += 1
            continue
        rec = {
            "row_num": row_num,
            "source_file": SERVICE_CATEGORIES_SOURCE,
            "service": service,
        }
        for f in ("doctor_type", "duration", "service_kind", "format", "periodicity", "qualification"):
            rec[f] = _cell(raw, _SERVICE_CAT_POS[f]) or None
        rows.append(rec)
    return rows, skipped


def ingest_service_categories(project_id: int, log=print, database: str | None = None,
                              spreadsheet_id: str | None = None,
                              sheet_name: str = SERVICE_CATEGORIES_SHEET_NAME) -> dict:
    """Тянет вкладку «Категорирование услуг» через Google Sheets API и пишет в realt_service_categories."""
    return _ingest_flat(project_id, log, database, spreadsheet_id, sheet_name,
                        parse_service_categories, "realt_service_categories",
                        SERVICE_CATEGORIES_COLUMNS)


def parse_employees(values: list[list[str]]) -> tuple[list[dict], int]:
    """Вкладка «Справочник сотрудников» (ID сотрудника → ФИО) → записи.

    Строка — данные, если есть «ID Сотрудника» (col 1); иначе пропуск.
    """
    rows, skipped = [], 0
    for row_num, raw in enumerate(values[1:], start=2):
        employee_id = _cell(raw, _EMPLOYEES_POS["employee_id"])
        if not employee_id:
            skipped += 1
            continue
        rows.append({
            "row_num": row_num,
            "source_file": EMPLOYEES_SOURCE,
            "employee_id": employee_id,
            "full_name": _cell(raw, _EMPLOYEES_POS["full_name"]) or None,
        })
    return rows, skipped


def ingest_employees(project_id: int, log=print, database: str | None = None,
                     spreadsheet_id: str | None = None,
                     sheet_name: str = EMPLOYEES_SHEET_NAME) -> dict:
    """Тянет вкладку «Справочник сотрудников» через Google Sheets API и пишет в realt_employees."""
    return _ingest_flat(project_id, log, database, spreadsheet_id, sheet_name,
                        parse_employees, "realt_employees", EMPLOYEES_COLUMNS)


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


def ingest_expenses(project_id: int, log=print, database: str | None = None,
                    spreadsheet_id: str | None = None, sheet_name: str = EXPENSES_SHEET_NAME) -> dict:
    """Тянет вкладку «Остальные расходы» через Google Sheets API и пишет в realt_expenses.

    Контракт как у ingest_payroll (project_id/database аргументами, log-колбэк,
    ValueError вместо sys.exit, summary-dict), источник — API. spreadsheet_id по
    умолчанию из GSHEETS_SPREADSHEET_ID.
    """
    if spreadsheet_id is None:
        spreadsheet_id = os.environ["GSHEETS_SPREADSHEET_ID"]

    log(f"  Читаю вкладку «{sheet_name}» из Google Sheets…")
    values = read_tab(spreadsheet_id, sheet_name)
    rows, skipped = parse_expenses(values)
    if skipped:
        log(f"    Пропущено ячеек-статей без суммы («-»/пусто): {skipped}")
    if not rows:
        raise ValueError("Не найдено ни одной строки расходов во вкладке")

    for row in rows:
        row["project_id"] = project_id
        row["is_shaa"] = int(row["is_shaa"])  # bool → UInt8

    client = get_client(database=database)
    data = [[row.get(col) for col in EXPENSES_COLUMNS] for row in rows]
    client.insert("realt_expenses", data, column_names=EXPENSES_COLUMNS)
    log(f"Загружено {len(data)} строк в realt_expenses.")

    return {"rows": len(data), "skipped": skipped}


def _ingest_flat(project_id: int, log, database: str | None, spreadsheet_id: str | None,
                  sheet_name: str, parse_fn, table: str, columns: list[str]) -> dict:
    """Общий каркас ingest_* для плоских регистров (bank_account/cash/accruals)."""
    if spreadsheet_id is None:
        spreadsheet_id = os.environ["GSHEETS_SPREADSHEET_ID"]

    log(f"  Читаю вкладку «{sheet_name}» из Google Sheets…")
    values = read_tab(spreadsheet_id, sheet_name)
    rows, skipped = parse_fn(values)
    if skipped:
        log(f"    Пропущено строк без суммы (пустые/декоративные): {skipped}")
    if not rows:
        raise ValueError(f"Не найдено ни одной строки во вкладке «{sheet_name}»")

    for row in rows:
        row["project_id"] = project_id

    client = get_client(database=database)
    data = [[row.get(col) for col in columns] for row in rows]
    client.insert(table, data, column_names=columns)
    log(f"Загружено {len(data)} строк в {table}.")

    return {"rows": len(data), "skipped": skipped}


def ingest_bank_account(project_id: int, log=print, database: str | None = None,
                        spreadsheet_id: str | None = None,
                        sheet_name: str = BANK_ACCOUNT_SHEET_NAME) -> dict:
    """Тянет вкладку «Расчетный счет» через Google Sheets API и пишет в realt_bank_account."""
    return _ingest_flat(project_id, log, database, spreadsheet_id, sheet_name,
                        parse_bank_account, "realt_bank_account", BANK_ACCOUNT_COLUMNS)


def ingest_cash(project_id: int, log=print, database: str | None = None,
                spreadsheet_id: str | None = None, sheet_name: str = CASH_SHEET_NAME) -> dict:
    """Тянет вкладку «Наличные» через Google Sheets API и пишет в realt_cash."""
    return _ingest_flat(project_id, log, database, spreadsheet_id, sheet_name,
                        parse_cash, "realt_cash", CASH_COLUMNS)


def ingest_accruals(project_id: int, log=print, database: str | None = None,
                    spreadsheet_id: str | None = None,
                    sheet_name: str = ACCRUALS_SHEET_NAME) -> dict:
    """Тянет вкладку «Начисления» через Google Sheets API и пишет в realt_accruals."""
    return _ingest_flat(project_id, log, database, spreadsheet_id, sheet_name,
                        parse_accruals, "realt_accruals", ACCRUALS_COLUMNS)
