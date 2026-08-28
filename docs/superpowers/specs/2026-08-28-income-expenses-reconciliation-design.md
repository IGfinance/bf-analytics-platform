# Дизайн: Сверка «Доходы и расходы» с еженедельными отчётами WB

**Дата:** 2026-08-28  
**Статус:** Согласован  
**Затрагиваемые файлы:** `webapp/app.py`, новые `wb_income_expenses_core.py`, `schema_wb_income_expenses.sql`

---

## Контекст

Пользователь ежемесячно выгружает из WB отчёт «Доходы и расходы» (по карточкам товаров).
Этот отчёт содержит агрегированные суммы по SKU за выбранный период.
Параллельно в ClickHouse хранятся сырые еженедельные детальные отчёты (`wb_reports`),
из которых Metabase считает те же метрики.

Задача: загружать «Доходы и расходы» через веб-форму, сохранять агрегированные итоги
в ClickHouse и автоматически сравнивать их с расчётами по `wb_reports` — чтобы видеть
расхождения и доверять цифрам в дашборде.

---

## Структура входного файла

Файл: WB «Детальный отчёт по доходам и расходам по карточкам товаров» (`.xlsx`).

**Лист «Общая информация»:**
- Строка с `Выбранный период` → `С YYYY-MM-DD по YYYY-MM-DD` (источник дат для сверки)

**Лист «Детальная информация»:**
- Строка 1: заголовок (игнорируется)
- Строка 2: заголовки колонок
- Строки 3+: данные по каждому SKU

Используемые колонки (только «текущий период», без `(предыдущий период)`):

| Колонка в файле | Поле в таблице |
|---|---|
| `Итог, ₽` | `total_rub` |
| `Продажи, ₽` | `sales_rub` |
| `Продажи, шт` | `n_sales` |
| `Возвраты, ₽` | `returns_rub` |
| `Возвраты, шт` | `n_returns` |
| `Логистика, ₽` | `logistics_rub` |
| `Штрафы, ₽` | `fines_rub` |
| `Комиссия WB, ₽` | `commission_rub` |
| `Эквайринг, ₽` | `acquiring_rub` |
| `Потери, подмены и товары с дефектами, ₽` | `losses_rub` |
| `Доплаты, ₽` | `bonuses_rub` |
| `Программа лояльности, ₽` | `loyalty_rub` |

Все колонки суммируются по всем строкам-SKU → одна запись на файл.

---

## Новая таблица ClickHouse: `wb_income_expenses`

```sql
CREATE TABLE IF NOT EXISTS wb_income_expenses
(
    cabinet        String,
    period_start   Date,
    period_end     Date,
    n_sales        Int64,
    n_returns      Int64,
    sales_rub      Float64,
    returns_rub    Float64,
    logistics_rub  Float64,
    fines_rub      Float64,
    commission_rub Float64,
    acquiring_rub  Float64,
    losses_rub     Float64,
    bonuses_rub    Float64,
    loyalty_rub    Float64,
    total_rub      Float64,
    source_file    String,
    loaded_at      DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
PARTITION BY toYYYYMM(period_start)
ORDER BY (cabinet, period_start)
```

Дедупликация по `(cabinet, period_start)` — повторная загрузка того же месяца перезаписывает запись.

DDL применяется вручную на сервере (как `schema_wb.sql` и `schema_wb_summary.sql`) — **не через Metabase**. Файл сохраняется в `schema_wb_income_expenses.sql` в корне проекта.

---

## Новый модуль: `wb_income_expenses_core.py`

`get_client()` импортируется из `wb_core.py` — не дублируется (правило из ревью PR #1).
Все SQL-запросы через `client.query(sql, parameters={...})` — без f-string с пользовательскими данными.

### `parse_income_expenses(path: Path) -> dict`

Разбирает один `.xlsx` файл:
1. Читает `period_start`, `period_end` из листа «Общая информация»
2. Читает заголовки из строки 2 листа «Детальная информация»
3. Суммирует нужные колонки по всем строкам-SKU
4. Возвращает dict с периодом и агрегированными значениями

### `ingest_files(paths: list[Path], cabinet: str, log) -> dict`

Для каждого файла:
1. Вызывает `parse_income_expenses()`
2. Делает `INSERT` в `wb_income_expenses` через параметризованный запрос
3. Возвращает `{"files": N, "rows": N}`

### `reconcile_income_expenses(client, cabinet: str, log) -> list[tuple]`

1. Читает все записи из `wb_income_expenses FINAL` по кабинету
2. Для каждой записи делает SELECT из `wb_reports` за тот же `period_start..period_end`
   используя формулы из `wb_metrics_by_month.sql` (адаптированные под диапазон дат)
3. Сравнивает 8 метрик, возвращает строки: `(metric_name, file_value, ch_value, diff, tolerance, is_ok)`

---

## Сравниваемые метрики

Фильтрация ClickHouse: `WHERE sale_date IS NOT NULL AND sale_date >= period_start AND sale_date <= period_end`

| # | Метрика | Из файла | Из wb_reports (ClickHouse) | Tolerance |
|---|---|---|---|---|
| 01 | Кол-во продаж | `n_sales − n_returns` | `sumIf(qty, 'продажа') − sumIf(qty, 'возврат')` | 5 |
| 02 | Продажи + СПП | `sales_rub + returns_rub` | `sumIf(retail_price_with_discount, продажа) − sumIf(..., возврат)` | 500 |
| 05 | Комиссия ВБ | `commission_rub + acquiring_rub` | `(ah_sale − ah_ret) − (t_sale − t_ret)` | 500 |
| 07 | Логистика | `logistics_rub` | `−sumIf(delivery_service_cost, 'Логистика'/'Коррекция логистики')` | 500 |
| 08 | Штрафы | `fines_rub` | `−sum(total_fines)` | 100 |
| 09 | Доплаты | `bonuses_rub` | `−sum(wb_commission_correction)` | 100 |
| 13 | Скидка Wibes | `loyalty_rub` | `sum(loyalty_discount_compensation) − sum(loyalty_program_cost) − sum(loyalty_points_deducted)` | 500 |
| 15 | К перечислению | `total_rub` | `k_perech_tovar + pryamaya + obratnaya + shtrafy + doplaty + khranenie + platnaya_priemka + uderzhanie + skidka_wibes + promo` | 1000 |

**Примечание по tolerance:** значения предварительные, уточняются после первого прогона
на реальных данных. Расхождение по дате (sale_date vs дата операции) — ожидаемо для
хранения/приёмки/штрафов, за полный месяц сходится лучше.

**Примечание по 07.03:** `transport_warehouse_compensation` пока не включена ни в Логистику,
ни в К перечислению — ждём сверки. Если 15 «К перечислению» будет регулярно расходиться,
это сигнал добавить её в формулу.

---

## Новые маршруты Flask

### `GET /income-expenses`
Форма загрузки — идентична `/summary`:
- Datalist кабинетов из `wb_reports`
- Один файл `.xlsx`
- Кнопка «Загрузить и сверить»

### `POST /upload-income-expenses`
1. Валидация кабинета и файла
2. Сохранение во временный файл
3. `ingest_files()` → запись в ClickHouse
4. `reconcile_income_expenses()` → сравнение
5. Рендер таблицы результатов

**Страница результатов** — таблица:

```
Период: 2026-03-01 — 2026-03-31     Кабинет: CloudSix

Метрика               | Файл         | ClickHouse   | Разница   | Статус
──────────────────────┼──────────────┼──────────────┼───────────┼────────
01 Кол-во продаж      |        4 421 |        4 398 |       -23 |  ⚠️
02 Продажи + СПП      | 9 595 316 ₽  | 9 571 204 ₽  |  -24 112  |  ⚠️
05 Комиссия ВБ        |-3 154 009 ₽  |-3 148 201 ₽  |    5 808  |  ✅
07 Логистика          |  -350 448 ₽  |  -352 100 ₽  |   -1 652  |  ✅
08 Штрафы             |    -2 043 ₽  |    -2 043 ₽  |        0  |  ✅
09 Доплаты            |          0 ₽ |          0 ₽ |        0  |  ✅
13 Скидка Wibes       |          0 ₽ |          0 ₽ |        0  |  ✅
15 К перечислению     | 6 098 540 ₽  | 6 069 004 ₽  |  -29 536  |  ⚠️
```

✅ = `|разница| ≤ tolerance`, ⚠️ = превышает допуск.

---

## Навигация

Добавить в `_NAV`:
```html
<a href="income-expenses">Доходы и расходы + сверка</a>
```

---

## Что НЕ входит в этот дизайн

- Разбивка по SKU (будущее ТЗ)
- История загрузок на отдельной странице
- Сравнение нескольких кабинетов сразу
- Включение `transport_warehouse_compensation` в формулу 15

---

## Definition of Done

- [ ] Таблица `wb_income_expenses` создана в ClickHouse
- [ ] `parse_income_expenses()` корректно читает период и суммирует колонки
- [ ] `ingest_files()` сохраняет данные, повторная загрузка перезаписывает
- [ ] `reconcile_income_expenses()` возвращает 8 метрик с корректными знаками
- [ ] Форма `/income-expenses` работает, кабинет из datalist
- [ ] Страница результатов показывает таблицу с ✅/⚠️
- [ ] Загрузка 6 месячных файлов прошла без ошибок
- [ ] Старые маршруты (детальный, сводный) не сломаны
- [ ] Нет секретов в коде, все SQL через параметры
