# Сверка «Доходы и расходы» Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Загружать WB-отчёт «Доходы и расходы» через веб-форму, хранить агрегированные итоги в ClickHouse и сравнивать 8 метрик с данными из `wb_reports`.

**Architecture:** Новый модуль `wb_income_expenses_core.py` отвечает за парсинг xlsx, загрузку в таблицу `wb_income_expenses` и сверку с `wb_reports`. Flask-приложение получает два новых маршрута (`/income-expenses`, `/upload-income-expenses`) по образцу существующих `/summary` и `/upload-summary`.

**Tech Stack:** Python 3.11, openpyxl, clickhouse-connect, Flask, pytest

## Global Constraints

- `get_client()` — импортировать из `wb_core.py`, не переопределять
- Все SQL-запросы — только через `client.query(sql, parameters={...})`, никаких f-string с пользовательскими данными
- Схема таблицы — в отдельном `schema_wb_income_expenses.sql`, применяется вручную на сервере (не через Metabase)
- `PARTITION BY toYYYYMM(period_start)` — обязательно в DDL, как у других таблиц
- `ReplacingMergeTree(loaded_at)` + `FINAL` в SELECT — дедупликация повторных загрузок
- Секреты — только из `.env` / `load_dotenv`
- Пушить только в ветку `draft`

---

## File Map

| Файл | Действие | Назначение |
|---|---|---|
| `schema_wb_income_expenses.sql` | Создать | DDL таблицы `wb_income_expenses` |
| `wb_income_expenses_core.py` | Создать | Парсинг, загрузка, сверка |
| `tests/test_income_expenses_parse.py` | Создать | Unit-тесты парсера |
| `webapp/app.py` | Изменить | Новые маршруты + шаблоны + nav |
| `requirements.txt` | Изменить | Добавить pytest |

---

## Task 1: DDL — схема таблицы `wb_income_expenses`

**Files:**
- Create: `schema_wb_income_expenses.sql`

**Interfaces:**
- Produces: таблица `wb_income_expenses` в ClickHouse, которую используют Task 3 и Task 4

- [ ] **Шаг 1: Создать файл схемы**

Создать `schema_wb_income_expenses.sql` в корне проекта:

```sql
-- Агрегированные итоги отчёта WB «Доходы и расходы» за период.
-- Одна строка на (cabinet, period_start). Загружается через wb_income_expenses_core.py.
-- Повторная загрузка того же периода перезаписывает запись (ReplacingMergeTree).
-- Применять вручную на сервере: clickhouse-client < schema_wb_income_expenses.sql

CREATE TABLE IF NOT EXISTS wb_income_expenses
(
    cabinet        String,
    period_start   Date,
    period_end     Date,

    -- Количественные показатели
    n_sales        Int64,    -- «Продажи, шт»
    n_returns      Int64,    -- «Возвраты, шт»

    -- Финансовые показатели (знак как в файле: расходы отрицательные)
    sales_rub      Float64,  -- «Продажи, ₽»
    returns_rub    Float64,  -- «Возвраты, ₽»       (отрицательное)
    logistics_rub  Float64,  -- «Логистика, ₽»      (отрицательное)
    fines_rub      Float64,  -- «Штрафы, ₽»         (отрицательное)
    commission_rub Float64,  -- «Комиссия WB, ₽»    (отрицательное)
    acquiring_rub  Float64,  -- «Эквайринг, ₽»      (отрицательное)
    losses_rub     Float64,  -- «Потери, подмены...»
    bonuses_rub    Float64,  -- «Доплаты, ₽»
    loyalty_rub    Float64,  -- «Программа лояльности, ₽»
    total_rub      Float64,  -- «Итог, ₽»            = фактическое К перечислению

    source_file    String,
    loaded_at      DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
PARTITION BY toYYYYMM(period_start)
ORDER BY (cabinet, period_start);
```

- [ ] **Шаг 2: Применить схему на сервере**

```bash
sshpass -p 'ПАРОЛЬ' ssh root@91.245.225.207 \
  "cd /var/www/report.finance-black.ru && clickhouse-client --query=\"$(cat schema_wb_income_expenses.sql)\""
```

Или через SSH-туннель локально:
```bash
clickhouse-client --host 127.0.0.1 --port 9000 < schema_wb_income_expenses.sql
```

Ожидаемый вывод: команда завершится без ошибок.

- [ ] **Шаг 3: Проверить создание таблицы**

```bash
clickhouse-client --host 127.0.0.1 --port 9000 \
  --query "DESCRIBE TABLE wb_income_expenses"
```

Ожидаемый вывод: список колонок `cabinet`, `period_start`, ... `loaded_at`.

- [ ] **Шаг 4: Закоммитить**

```bash
git add schema_wb_income_expenses.sql
git commit -m "feat: DDL для таблицы wb_income_expenses"
```

---

## Task 2: Парсер — `parse_income_expenses()`

**Files:**
- Create: `wb_income_expenses_core.py`
- Create: `tests/test_income_expenses_parse.py`

**Interfaces:**
- Consumes: ничего из предыдущих задач
- Produces:
  ```python
  # wb_income_expenses_core.py
  def parse_income_expenses(path: Path) -> dict:
      """
      Возвращает:
      {
          "period_start": date,
          "period_end": date,
          "source_file": str,
          "n_sales": int,
          "n_returns": int,
          "sales_rub": float,
          "returns_rub": float,
          "logistics_rub": float,
          "fines_rub": float,
          "commission_rub": float,
          "acquiring_rub": float,
          "losses_rub": float,
          "bonuses_rub": float,
          "loyalty_rub": float,
          "total_rub": float,
      }
      Raises ValueError если не удалось прочитать период.
      """
  ```

- [ ] **Шаг 1: Добавить pytest в requirements.txt**

```
pandas
openpyxl
pyyaml
clickhouse-connect
python-dotenv
flask
pytest
```

- [ ] **Шаг 2: Написать падающий тест для парсера**

Создать `tests/test_income_expenses_parse.py`:

```python
import pytest
from datetime import date
from pathlib import Path
from wb_income_expenses_core import parse_income_expenses

# Путь к реальным тестовым файлам (локально)
MARCH = Path("/Users/ilya/Downloads/Gmail/Март.xlsx")
AUGUST = Path("/Users/ilya/Downloads/Gmail/Август.xlsx")


def test_parse_period_march():
    result = parse_income_expenses(MARCH)
    assert result["period_start"] == date(2026, 3, 1)
    assert result["period_end"] == date(2026, 3, 31)


def test_parse_period_august_partial():
    """Август — неполный месяц (01-08 по 23-08)."""
    result = parse_income_expenses(AUGUST)
    assert result["period_start"] == date(2026, 8, 1)
    assert result["period_end"] == date(2026, 8, 23)


def test_parse_source_file():
    result = parse_income_expenses(MARCH)
    assert result["source_file"] == "Март.xlsx"


def test_parse_numeric_totals_march():
    result = parse_income_expenses(MARCH)
    # Продажи шт — целое, положительное
    assert isinstance(result["n_sales"], int)
    assert result["n_sales"] > 0
    # Возвраты шт — целое, неотрицательное
    assert isinstance(result["n_returns"], int)
    assert result["n_returns"] >= 0
    # Продажи ₽ — положительные
    assert result["sales_rub"] > 0
    # Возвраты ₽ — отрицательные (как в файле)
    assert result["returns_rub"] <= 0
    # Логистика ₽ — отрицательная
    assert result["logistics_rub"] <= 0
    # Комиссия ₽ — отрицательная
    assert result["commission_rub"] <= 0
    # Итог — верифицируем диапазон (из ручного подсчёта по файлу Март)
    assert 5_000_000 < result["total_rub"] < 8_000_000


def test_parse_known_totals_march():
    """Проверяем конкретные суммы из файла Март (вычислены заранее)."""
    result = parse_income_expenses(MARCH)
    assert result["n_sales"] == 4614
    assert result["n_returns"] == 193
    assert abs(result["sales_rub"] - 10_037_087.19) < 1.0
    assert abs(result["returns_rub"] - (-441_771.12)) < 1.0
    assert abs(result["logistics_rub"] - (-350_448.69)) < 1.0
    assert abs(result["fines_rub"] - (-2_043.70)) < 1.0
    assert abs(result["commission_rub"] - (-2_863_919.82)) < 1.0
    assert abs(result["acquiring_rub"] - (-290_089.42)) < 1.0
    assert abs(result["losses_rub"] - 12_947.03) < 1.0
    assert abs(result["bonuses_rub"] - 0.0) < 1.0
    assert abs(result["loyalty_rub"] - 0.0) < 1.0
    assert abs(result["total_rub"] - 6_098_540.66) < 1.0


def test_parse_missing_file():
    with pytest.raises(Exception):
        parse_income_expenses(Path("/tmp/nonexistent.xlsx"))
```

- [ ] **Шаг 3: Запустить тесты — убедиться что падают**

```bash
cd "/Users/ilya/PyCharmMiscProject/BF (Ilyas : Ilya)/BF_2/BF_2"
python -m pytest tests/test_income_expenses_parse.py -v 2>&1 | head -20
```

Ожидаемый вывод: `ImportError: No module named 'wb_income_expenses_core'`

- [ ] **Шаг 4: Реализовать `parse_income_expenses()`**

Создать `wb_income_expenses_core.py`:

```python
#!/usr/bin/env python3
"""
Парсинг, загрузка и сверка отчёта WB «Доходы и расходы».
Используется веб-формой (webapp/app.py).
"""

import re
from datetime import date
from pathlib import Path
from typing import Callable

import openpyxl
from dotenv import load_dotenv

from wb_core import get_client, SCRIPT_DIR  # get_client не дублируем

load_dotenv(SCRIPT_DIR / ".env")

# Маппинг заголовков xlsx → имена полей таблицы.
# Только «текущий период» — колонки с «(предыдущий период)» игнорируются.
_COL_MAP = {
    "Итог, ₽":                                          "total_rub",
    "Продажи, ₽":                                       "sales_rub",
    "Продажи, шт":                                      "n_sales",
    "Возвраты, ₽":                                      "returns_rub",
    "Возвраты, шт":                                     "n_returns",
    "Логистика, ₽":                                     "logistics_rub",
    "Штрафы, ₽":                                        "fines_rub",
    "Комиссия WB, ₽":                                   "commission_rub",
    "Эквайринг, ₽":                                     "acquiring_rub",
    "Потери, подмены и товары с дефектами, ₽":         "losses_rub",
    "Доплаты, ₽":                                       "bonuses_rub",
    "Программа лояльности, ₽":                         "loyalty_rub",
}

_INT_FIELDS = {"n_sales", "n_returns"}

INSERT_COLUMNS = [
    "cabinet", "period_start", "period_end",
    "n_sales", "n_returns",
    "sales_rub", "returns_rub", "logistics_rub", "fines_rub",
    "commission_rub", "acquiring_rub", "losses_rub", "bonuses_rub",
    "loyalty_rub", "total_rub",
    "source_file",
]

# (metric_label, ch_alias, file_formula, tolerance)
# file_formula — функция, принимающая dict с полями таблицы, возвращает float
METRICS = [
    ("01 Кол-во продаж",  "kol_prodazh",  lambda r: r["n_sales"] - r["n_returns"],                5),
    ("02 Продажи + СПП",  "prodazhi_spp", lambda r: r["sales_rub"] + r["returns_rub"],           500),
    ("05 Комиссия ВБ",    "komissiya",    lambda r: r["commission_rub"] + r["acquiring_rub"],     500),
    ("07 Логистика",      "logistika",    lambda r: r["logistics_rub"],                           500),
    ("08 Штрафы",         "shtrafy",      lambda r: r["fines_rub"],                               100),
    ("09 Доплаты",        "doplaty",      lambda r: r["bonuses_rub"],                             100),
    ("13 Скидка Wibes",   "skidka_wibes", lambda r: r["loyalty_rub"],                             500),
    ("15 К перечислению", "k_perech",     lambda r: r["total_rub"],                              1000),
]


def parse_income_expenses(path: Path) -> dict:
    """
    Разбирает один xlsx «Доходы и расходы».
    Возвращает dict с period_start, period_end, source_file и суммами по колонкам.
    Raises ValueError если не удалось прочитать период или листы не найдены.
    """
    try:
        wb = openpyxl.load_workbook(path, data_only=True)
    except Exception as e:
        raise ValueError(f"Не удалось открыть файл «{path.name}»: {e}") from e

    # --- Период ---
    try:
        ws_info = wb["Общая информация"]
    except KeyError:
        raise ValueError(f"Лист «Общая информация» не найден в «{path.name}»")

    period_start = period_end = None
    for row in ws_info.iter_rows(values_only=True):
        if row and row[0] == "Выбранный период":
            m = re.match(r"С (\d{4}-\d{2}-\d{2}) по (\d{4}-\d{2}-\d{2})", str(row[1] or ""))
            if m:
                period_start = date.fromisoformat(m.group(1))
                period_end = date.fromisoformat(m.group(2))
            break

    if not period_start or not period_end:
        raise ValueError(f"Не удалось прочитать период из «{path.name}»")

    # --- Данные по SKU ---
    try:
        ws_data = wb["Детальная информация"]
    except KeyError:
        raise ValueError(f"Лист «Детальная информация» не найден в «{path.name}»")

    rows = list(ws_data.iter_rows(values_only=True))
    if len(rows) < 3:
        raise ValueError(f"Слишком мало строк в «{path.name}»")

    headers = rows[1]  # строка 2 — заголовки
    col_idx = {}
    for i, h in enumerate(headers):
        if h in _COL_MAP:
            col_idx[_COL_MAP[h]] = i

    totals: dict = {field: 0.0 for field in _COL_MAP.values()}
    for row in rows[2:]:
        for field, idx in col_idx.items():
            val = row[idx]
            if isinstance(val, (int, float)):
                totals[field] += float(val)

    for field in _INT_FIELDS:
        totals[field] = int(round(totals[field]))

    return {
        "period_start": period_start,
        "period_end": period_end,
        "source_file": path.name,
        **totals,
    }
```

- [ ] **Шаг 5: Запустить тесты — убедиться что проходят**

```bash
cd "/Users/ilya/PyCharmMiscProject/BF (Ilyas : Ilya)/BF_2/BF_2"
python -m pytest tests/test_income_expenses_parse.py -v
```

Ожидаемый вывод: `6 passed`

- [ ] **Шаг 6: Закоммитить**

```bash
git add wb_income_expenses_core.py tests/test_income_expenses_parse.py requirements.txt
git commit -m "feat: парсер wb_income_expenses_core — parse_income_expenses() + тесты"
```

---

## Task 3: Загрузка в ClickHouse — `ingest_files()`

**Files:**
- Modify: `wb_income_expenses_core.py` (добавить функцию)

**Interfaces:**
- Consumes: `parse_income_expenses(path)` из Task 2
- Produces:
  ```python
  def ingest_files(paths: list[Path], cabinet: str, log: Callable = print) -> dict:
      """Возвращает {"files": int, "rows": int}"""
  ```

**Требования:** таблица `wb_income_expenses` должна существовать в ClickHouse (Task 1).

- [ ] **Шаг 1: Добавить `ingest_files()` в конец `wb_income_expenses_core.py`**

```python
def ingest_files(paths: list[Path], cabinet: str, log: Callable = print) -> dict:
    """
    Парсит список xlsx «Доходы и расходы» и загружает в wb_income_expenses.
    Повторная загрузка того же (cabinet, period_start) перезапишет запись.
    """
    rows_data = []
    for path in paths:
        parsed = parse_income_expenses(path)
        log(f"  {path.name}: {parsed['period_start']} — {parsed['period_end']}")
        row = [cabinet] + [parsed[col] for col in INSERT_COLUMNS[1:]]
        rows_data.append(row)

    if not rows_data:
        log("Нет файлов для загрузки.")
        return {"files": 0, "rows": 0}

    client = get_client()
    client.insert("wb_income_expenses", rows_data, column_names=INSERT_COLUMNS)
    log(f"Загружено {len(rows_data)} записей в wb_income_expenses.")

    return {"files": len(paths), "rows": len(rows_data)}
```

- [ ] **Шаг 2: Проверить загрузку вручную (требует ClickHouse)**

```bash
cd "/Users/ilya/PyCharmMiscProject/BF (Ilyas : Ilya)/BF_2/BF_2"
python3 -c "
from pathlib import Path
from wb_income_expenses_core import ingest_files

files = [
    Path('/Users/ilya/Downloads/Gmail/Март.xlsx'),
    Path('/Users/ilya/Downloads/Gmail/Апрель.xlsx'),
    Path('/Users/ilya/Downloads/Gmail/Май.xlsx'),
    Path('/Users/ilya/Downloads/Gmail/Июнь.xlsx'),
    Path('/Users/ilya/Downloads/Gmail/Июль.xlsx'),
    Path('/Users/ilya/Downloads/Gmail/Август.xlsx'),
]
result = ingest_files(files, 'CloudSix')
print(result)
"
```

Ожидаемый вывод: `{'files': 6, 'rows': 6}`

- [ ] **Шаг 3: Проверить данные в ClickHouse**

```bash
clickhouse-client --host 127.0.0.1 --port 9000 \
  --query "SELECT cabinet, period_start, period_end, n_sales, total_rub FROM wb_income_expenses FINAL ORDER BY period_start"
```

Ожидаемый вывод: 6 строк с периодами март–август.

- [ ] **Шаг 4: Закоммитить**

```bash
git add wb_income_expenses_core.py
git commit -m "feat: ingest_files() для wb_income_expenses"
```

---

## Task 4: Сверка — `reconcile_income_expenses()`

**Files:**
- Modify: `wb_income_expenses_core.py` (добавить функцию и SQL)

**Interfaces:**
- Consumes:
  - `get_client()` из `wb_core`
  - таблица `wb_income_expenses` (Task 1 + 3)
  - таблица `wb_reports` (уже существует)
- Produces:
  ```python
  def reconcile_income_expenses(client, cabinet: str, log: Callable = print) -> list[tuple]:
      """
      Возвращает list[tuple] — по одному кортежу на (период × метрика):
      (period_start, period_end, metric_name, file_value, ch_value, diff, tolerance, is_ok)
      """
  ```

- [ ] **Шаг 1: Добавить SQL-запрос и `reconcile_income_expenses()` в `wb_income_expenses_core.py`**

```python
# SQL считает те же метрики, что wb_metrics_by_month.sql, но за произвольный диапазон дат.
# CS_K_TYPES — константа кода, не пользовательский ввод, поэтому зашита прямо в SQL
# (как в оригинальном Metabase-запросе) — без риска SQL-инъекции.
_RECONCILE_SQL = """
WITH cs_k AS (SELECT arrayJoin([
    'продажа', 'сторно продаж', 'авансовая оплата за товар без движения',
    'возврат', 'корректный возврат', 'корректная продажа',
    'компенсация брака', 'компенсация потерянного товара',
    'сторно возвратов', 'компенсация ущерба',
    'добровольная компенсация при возврате',
    'компенсация подмененного товара', 'частичная компенсация брака'
]) AS v)
SELECT
    -- 01 Кол-во продаж (n_sale - n_ret)
    coalesce(sumIf(qty, lowerUTF8(trim(payment_reason)) = 'продажа'), 0)
    - coalesce(sumIf(qty, lowerUTF8(trim(payment_reason)) = 'возврат'), 0)
        AS kol_prodazh,

    -- 02 Продажи + СПП (retail net)
    coalesce(sumIf(retail_price_with_discount,
        lowerUTF8(trim(payment_reason)) IN (SELECT v FROM cs_k)
        AND lowerUTF8(trim(document_type)) = 'продажа'), 0)
    - coalesce(sumIf(retail_price_with_discount,
        lowerUTF8(trim(payment_reason)) IN (SELECT v FROM cs_k)
        AND lowerUTF8(trim(document_type)) = 'возврат'), 0)
        AS prodazhi_spp,

    -- 05 Комиссия ВБ = К перечислению за товар − Продажи+СПП
    (
      coalesce(sumIf(payable_to_seller,
          lowerUTF8(trim(payment_reason)) IN (SELECT v FROM cs_k)
          AND lowerUTF8(trim(document_type)) = 'продажа'), 0)
      - coalesce(sumIf(payable_to_seller,
          lowerUTF8(trim(payment_reason)) IN (SELECT v FROM cs_k)
          AND lowerUTF8(trim(document_type)) = 'возврат'), 0)
    ) - (
      coalesce(sumIf(retail_price_with_discount,
          lowerUTF8(trim(payment_reason)) IN (SELECT v FROM cs_k)
          AND lowerUTF8(trim(document_type)) = 'продажа'), 0)
      - coalesce(sumIf(retail_price_with_discount,
          lowerUTF8(trim(payment_reason)) IN (SELECT v FROM cs_k)
          AND lowerUTF8(trim(document_type)) = 'возврат'), 0)
    )
        AS komissiya,

    -- 07 Логистика (прямая + обратная, знак отрицательный)
    -(coalesce(sumIf(delivery_service_cost,
        payment_reason IN ('Логистика', 'Коррекция логистики')), 0))
        AS logistika,

    -- 08 Штрафы (знак отрицательный)
    -(coalesce(sum(total_fines), 0)) AS shtrafy,

    -- 09 Доплаты (wb_commission_correction, знак отрицательный)
    -(coalesce(sum(wb_commission_correction), 0)) AS doplaty,

    -- 13 Скидка Wibes
    coalesce(sum(loyalty_discount_compensation), 0)
    - coalesce(sum(loyalty_program_cost), 0)
    - coalesce(sum(loyalty_points_deducted), 0)
        AS skidka_wibes,

    -- 15 К перечислению (все компоненты из метрик 06..14)
    (
      coalesce(sumIf(payable_to_seller,
          lowerUTF8(trim(payment_reason)) IN (SELECT v FROM cs_k)
          AND lowerUTF8(trim(document_type)) = 'продажа'), 0)
      - coalesce(sumIf(payable_to_seller,
          lowerUTF8(trim(payment_reason)) IN (SELECT v FROM cs_k)
          AND lowerUTF8(trim(document_type)) = 'возврат'), 0)
    )
    -(coalesce(sumIf(delivery_service_cost,
        payment_reason IN ('Логистика', 'Коррекция логистики')), 0))
    -(coalesce(sum(total_fines), 0))
    -(coalesce(sum(wb_commission_correction), 0))
    -(coalesce(sum(storage_cost), 0))
    -(coalesce(sum(acceptance_operations), 0))
    -(coalesce(sumIf(deductions,
        trim(REGEXP_REPLACE(REGEXP_REPLACE(logistics_fines_corrections_type,
            ',\\\\s*документ\\\\s*№\\\\s*\\\\d+', ''), '\\\\s+\\\\d+$', ''))
        NOT IN ('Оказание услуг «WB Продвижение»', 'Оказание услуг «ВБ.Продвижение»')
        OR logistics_fines_corrections_type IS NULL), 0))
    +(coalesce(sum(loyalty_discount_compensation), 0)
      - coalesce(sum(loyalty_program_cost), 0)
      - coalesce(sum(loyalty_points_deducted), 0))
    -(coalesce(sumIf(deductions,
        trim(REGEXP_REPLACE(REGEXP_REPLACE(logistics_fines_corrections_type,
            ',\\\\s*документ\\\\s*№\\\\s*\\\\d+', ''), '\\\\s+\\\\d+$', ''))
        IN ('Оказание услуг «WB Продвижение»', 'Оказание услуг «ВБ.Продвижение»')), 0))
        AS k_perech

FROM wb_reports FINAL
WHERE cabinet = {cabinet:String}
  AND sale_date IS NOT NULL
  AND sale_date >= {period_start:Date}
  AND sale_date <= {period_end:Date}
"""

_CH_ALIASES = ["kol_prodazh", "prodazhi_spp", "komissiya", "logistika",
               "shtrafy", "doplaty", "skidka_wibes", "k_perech"]


def reconcile_income_expenses(client, cabinet: str, log: Callable = print) -> list[tuple]:
    """
    Для каждого загруженного периода кабинета сравнивает 8 метрик
    из wb_income_expenses с расчётами по wb_reports.

    Возвращает list[tuple]:
    (period_start, period_end, metric_name, file_value, ch_value, diff, tolerance, is_ok)
    """
    ie_rows = client.query(
        "SELECT period_start, period_end, "
        "n_sales, n_returns, sales_rub, returns_rub, logistics_rub, fines_rub, "
        "commission_rub, acquiring_rub, losses_rub, bonuses_rub, loyalty_rub, total_rub "
        "FROM wb_income_expenses FINAL "
        "WHERE cabinet = {cabinet:String} ORDER BY period_start",
        parameters={"cabinet": cabinet},
    ).result_rows

    if not ie_rows:
        log(f"Нет записей в wb_income_expenses для cabinet='{cabinet}'")
        return []

    log(f"Сверка: {len(ie_rows)} период(ов) для кабинета '{cabinet}'")

    ie_fields = [
        "period_start", "period_end",
        "n_sales", "n_returns", "sales_rub", "returns_rub", "logistics_rub", "fines_rub",
        "commission_rub", "acquiring_rub", "losses_rub", "bonuses_rub", "loyalty_rub", "total_rub",
    ]

    results = []
    for ie_row in ie_rows:
        ie = dict(zip(ie_fields, ie_row))
        p_start = ie["period_start"]
        p_end = ie["period_end"]
        log(f"  {p_start} — {p_end}")

        ch_row = client.query(
            _RECONCILE_SQL,
            parameters={
                "cabinet": cabinet,
                "period_start": p_start,
                "period_end": p_end,
            },
        ).result_rows

        ch_values = dict(zip(_CH_ALIASES, ch_row[0])) if ch_row else {k: 0.0 for k in _CH_ALIASES}

        for metric_name, ch_alias, file_formula, tolerance in METRICS:
            file_val = float(file_formula(ie))
            ch_val = float(ch_values.get(ch_alias, 0.0))
            diff = abs(file_val - ch_val)
            is_ok = 1 if diff <= tolerance else 0
            label = "OK" if is_ok else f"MISMATCH {diff:.0f}"
            log(f"    [{label:>18}] {metric_name}  файл={file_val:.0f}  CH={ch_val:.0f}")
            results.append((p_start, p_end, metric_name, file_val, ch_val, diff, tolerance, is_ok))

    return results
```

- [ ] **Шаг 2: Проверить сверку вручную**

```bash
cd "/Users/ilya/PyCharmMiscProject/BF (Ilyas : Ilya)/BF_2/BF_2"
python3 -c "
from wb_core import get_client
from wb_income_expenses_core import reconcile_income_expenses
client = get_client()
rows = reconcile_income_expenses(client, 'CloudSix')
print(f'Всего строк: {len(rows)}')
mismatches = [r for r in rows if not r[7]]
print(f'Расхождений: {len(mismatches)}')
for r in mismatches:
    print(f'  {r[0]}  {r[2]}  файл={r[3]:.0f}  CH={r[4]:.0f}  diff={r[5]:.0f}')
"
```

Ожидаемый вывод: 48 строк (6 периодов × 8 метрик), список расхождений.

- [ ] **Шаг 3: Закоммитить**

```bash
git add wb_income_expenses_core.py
git commit -m "feat: reconcile_income_expenses() — сверка 8 метрик по периоду"
```

---

## Task 5: Flask — форма, маршруты, страница результатов

**Files:**
- Modify: `webapp/app.py`

**Interfaces:**
- Consumes:
  - `ingest_files(paths, cabinet, log)` → `{"files": int, "rows": int}` из Task 3
  - `reconcile_income_expenses(client, cabinet, log)` → `list[tuple]` из Task 4
  - `get_client()` из `wb_core` (уже импортирован в app.py)

- [ ] **Шаг 1: Добавить импорт в `webapp/app.py`**

В блок импортов (после строки с `from reconcile_wb import run_reconciliation`):

```python
from wb_income_expenses_core import (      # noqa: E402
    ingest_files as ingest_income_expenses,
    reconcile_income_expenses,
)
```

- [ ] **Шаг 2: Добавить ссылку в навигацию**

Заменить `_NAV`:

```python
_NAV = """
<nav>
  <a href="./">Детальный отчёт</a>
  <a href="summary">Сводный отчёт + сверка</a>
  <a href="income-expenses">Доходы и расходы + сверка</a>
</nav>
"""
```

- [ ] **Шаг 3: Добавить HTML-шаблоны**

После `SUMMARY_RESULT_HTML` добавить:

```python
IE_FORM_HTML = """
<!doctype html><html lang="ru"><head><meta charset="utf-8">
<title>Доходы и расходы + сверка</title>{{ style | safe }}</head>
<body>
  {{ nav | safe }}
  <h1>Загрузка отчёта «Доходы и расходы» + сверка</h1>
  <p class="hint">Загрузите файл «Детальный отчёт по доходам и расходам» (xlsx) за один месяц.
  Данные сохранятся в wb_income_expenses, затем автоматически сверятся с wb_reports.</p>
  {% if error %}<p class="error">{{ error }}</p>{% endif %}
  <form action="upload-income-expenses" method="post" enctype="multipart/form-data">
    <label for="cabinet">Кабинет</label>
    <input type="text" id="cabinet" name="cabinet" list="cabinets"
           placeholder="Выберите или введите новый..." autocomplete="off" required
           oninput="if(this.value==='+ Добавить новый кабинет'){this.value='';this.placeholder='Введите название нового кабинета';}">
    <datalist id="cabinets">
      <option value="+ Добавить новый кабинет">
      {% for c in cabinets %}<option value="{{ c }}">{% endfor %}
    </datalist>
    <p class="hint">Выберите из списка или введите название нового кабинета вручную.</p>

    <label for="file">Файл отчёта (.xlsx)</label>
    <input type="file" id="file" name="file" accept=".xlsx" required>

    <input type="submit" value="Загрузить и сверить">
  </form>
</body></html>
"""

IE_RESULT_HTML = """
<!doctype html><html lang="ru"><head><meta charset="utf-8">
<title>Результат сверки доходов и расходов</title>{{ style | safe }}
<style>
  .diff-ok   { color: #1a7a34; }
  .diff-warn { color: #c00; font-weight: 600; }
  td.num { text-align: right; font-variant-numeric: tabular-nums; }
</style>
</head>
<body>
  {{ nav | safe }}
  <h1>Результат загрузки и сверки</h1>
  {% if error %}
    <p class="error">Ошибка: {{ error }}</p>
  {% else %}
    <p class="ok">Загружено записей: {{ ingest_rows }}</p>

    {% if rows %}
      {% set ns = namespace(cur_period=None) %}
      {% for r in rows %}
        {% if r.period_start != ns.cur_period %}
          {% if ns.cur_period is not none %}</table>{% endif %}
          {% set ns.cur_period = r.period_start %}
          <h2>{{ r.period_start }} — {{ r.period_end }}</h2>
          <table>
            <tr>
              <th>Метрика</th>
              <th>Файл</th>
              <th>ClickHouse</th>
              <th>Разница</th>
              <th>Допуск</th>
              <th>Статус</th>
            </tr>
        {% endif %}
        <tr class="{{ 'fail' if not r.is_ok else '' }}">
          <td>{{ r.metric_name }}</td>
          <td class="num">{{ "%.0f"|format(r.file_value) }}</td>
          <td class="num">{{ "%.0f"|format(r.ch_value) }}</td>
          <td class="num {{ 'diff-warn' if not r.is_ok else 'diff-ok' }}">
            {{ "%+.0f"|format(r.ch_value - r.file_value) }}
          </td>
          <td class="num">± {{ "%.0f"|format(r.tolerance) }}</td>
          <td>{{ '✅' if r.is_ok else '⚠️' }}</td>
        </tr>
      {% endfor %}
      {% if rows %}</table>{% endif %}
    {% else %}
      <p class="warn">Нет данных для сверки — загрузите файл и попробуйте снова.</p>
    {% endif %}
  {% endif %}
  {% if logs %}<pre>{{ logs|join('\n') }}</pre>{% endif %}
  <a href="income-expenses">← Загрузить ещё</a>
</body></html>
"""
```

- [ ] **Шаг 4: Добавить маршруты**

Перед `if __name__ == "__main__":` добавить:

```python
# ---------------------------------------------------------------------------
# Routes — доходы и расходы + сверка
# ---------------------------------------------------------------------------

@app.route("/income-expenses", methods=["GET"])
@requires_auth
def income_expenses_form():
    return render_template_string(
        IE_FORM_HTML, style=_BASE_STYLE, nav=_NAV,
        error=None, cabinets=get_cabinets(),
    )


@app.route("/upload-income-expenses", methods=["POST"])
@requires_auth
def upload_income_expenses():
    cabinet = request.form.get("cabinet", "").strip()
    f = request.files.get("file")

    if not cabinet:
        return render_template_string(
            IE_FORM_HTML, style=_BASE_STYLE, nav=_NAV,
            error="Укажите кабинет", cabinets=get_cabinets(),
        ), 400
    if not f or f.filename == "":
        return render_template_string(
            IE_FORM_HTML, style=_BASE_STYLE, nav=_NAV,
            error="Выберите файл", cabinets=get_cabinets(),
        ), 400

    filename = safe_filename(f.filename)
    if not filename.lower().endswith(".xlsx"):
        return render_template_string(
            IE_FORM_HTML, style=_BASE_STYLE, nav=_NAV,
            error="Файл должен быть .xlsx", cabinets=get_cabinets(),
        ), 400

    dest = UPLOAD_DIR / filename
    f.save(dest)

    logs = []
    try:
        ingest_result = ingest_income_expenses([dest], cabinet, log=logs.append)
        client = get_client()
        recon_rows = reconcile_income_expenses(client, cabinet, log=logs.append)
    except Exception as e:
        return render_template_string(
            IE_RESULT_HTML, style=_BASE_STYLE, nav=_NAV,
            error=str(e), ingest_rows=0, rows=[], logs=logs,
        ), 500
    finally:
        dest.unlink(missing_ok=True)

    FIELDS = [
        "period_start", "period_end", "metric_name",
        "file_value", "ch_value", "diff", "tolerance", "is_ok",
    ]
    rows = [dict(zip(FIELDS, r)) for r in recon_rows]

    return render_template_string(
        IE_RESULT_HTML, style=_BASE_STYLE, nav=_NAV,
        error=None,
        ingest_rows=ingest_result["rows"],
        rows=rows,
        logs=logs,
    )
```

- [ ] **Шаг 5: Запустить приложение локально и проверить форму**

```bash
cd "/Users/ilya/PyCharmMiscProject/BF (Ilyas : Ilya)/BF_2/BF_2"
python3 webapp/app.py
```

Открыть http://127.0.0.1:5001/income-expenses — должна отображаться форма с nav.
Загрузить `/Users/ilya/Downloads/Gmail/Март.xlsx`, кабинет `CloudSix`.
Убедиться: страница результатов показывает таблицу с 8 метриками за март.

- [ ] **Шаг 6: Проверить что старые маршруты не сломаны**

Открыть http://127.0.0.1:5001/ — форма детального отчёта работает.
Открыть http://127.0.0.1:5001/summary — форма сводного отчёта работает.

- [ ] **Шаг 7: Закоммитить**

```bash
git add webapp/app.py
git commit -m "feat(webapp): форма и результаты сверки «Доходы и расходы»"
```

---

## Task 6: Деплой на сервер

**Files:** нет изменений кода

- [ ] **Шаг 1: Применить схему на сервере**

```bash
sshpass -p 'ПАРОЛЬ' scp schema_wb_income_expenses.sql \
  root@91.245.225.207:/var/www/report.finance-black.ru/schema_wb_income_expenses.sql

sshpass -p 'ПАРОЛЬ' ssh root@91.245.225.207 \
  "cd /var/www/report.finance-black.ru && \
   clickhouse-client --multiquery < schema_wb_income_expenses.sql && \
   echo 'Schema OK'"
```

- [ ] **Шаг 2: Задеплоить изменённые файлы**

```bash
for f in wb_income_expenses_core.py webapp/app.py requirements.txt; do
  sshpass -p 'ПАРОЛЬ' scp "$f" \
    "root@91.245.225.207:/var/www/report.finance-black.ru/$f"
done

sshpass -p 'ПАРОЛЬ' ssh root@91.245.225.207 \
  "cd /var/www/report.finance-black.ru && \
   source venv/bin/activate && \
   pip install -r requirements.txt -q && \
   systemctl restart report-cloudsix.service && \
   systemctl is-active report-cloudsix.service"
```

Ожидаемый вывод: `active`

- [ ] **Шаг 3: Смоук-тест на проде**

Открыть https://report.finance-black.ru/income-expenses → форма загрузки.
Загрузить один месячный файл, проверить результаты.

- [ ] **Шаг 4: Запушить в draft**

```bash
git push origin draft
```

---

## Чек-лист DoD (из design doc)

- [ ] Таблица `wb_income_expenses` создана в ClickHouse
- [ ] `parse_income_expenses()` корректно читает период и суммирует колонки (тесты проходят)
- [ ] `ingest_files()` сохраняет данные, повторная загрузка перезаписывает
- [ ] `reconcile_income_expenses()` возвращает 8 метрик с корректными знаками
- [ ] Форма `/income-expenses` работает, кабинет из datalist
- [ ] Страница результатов показывает таблицу с ✅/⚠️
- [ ] Загрузка 6 месячных файлов прошла без ошибок
- [ ] Старые маршруты (детальный, сводный) не сломаны
- [ ] Нет секретов в коде, все SQL через параметры
