# bf-analytics-platform

Платформа для загрузки и сверки финансовой отчётности Wildberries: приём
детальных и сводных еженедельных отчётов, хранение в ClickHouse, сверка
сводного отчёта с сырыми данными по правилам из YAML.

## Возможности

- Приём `.xlsx`-отчётов WB (детальных и сводных) через CLI или веб-форму
- Валидация и маппинг колонок (`column_mapping_wb.yaml`)
- Хранение сырых и сводных данных в ClickHouse
- Сверка сводного отчёта с детальными данными по конфигурируемым правилам
  (`reconciliation_rules_wb.yaml`)
- Проверка данных на аномалии (`check_wb.py`)
- Готовые запросы для дашбордов Metabase (`metabase_queries/`)

## Структура

```
├── wb_core.py                  # приём/парсинг детальных отчётов
├── wb_summary_core.py          # приём/парсинг сводных отчётов
├── reconcile_wb.py             # сверка сводного отчёта с сырыми данными
├── check_wb.py                 # проверка данных на аномалии
├── ingest_wb.py                # CLI-загрузка детальных отчётов
├── schema_wb.sql               # схема ClickHouse для сырых данных
├── schema_wb_summary.sql       # схема ClickHouse для сводных отчётов и результатов сверки
├── column_mapping_wb.yaml      # маппинг колонок отчёта WB → поля таблицы
├── reconciliation_rules_wb.yaml # правила сверки (формулы + допуски)
├── metabase_queries/           # SQL-запросы для дашбордов
├── webapp/                     # Flask-форма для ручной загрузки отчётов
└── docs/                       # техническое задание и ревью реализации
```

## Установка

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
cp .env.example .env            # заполнить реквизиты ClickHouse
cp webapp/.env.example webapp/.env  # логин/пароль веб-формы
```

## Использование

```bash
# Загрузка детального отчёта
python3 ingest_wb.py --cabinet "AcmeShop" --files "/path/to/reports/*.xlsx"

# Проверка данных на аномалии
python3 check_wb.py --cabinet AcmeShop

# Сверка сводного отчёта с сырыми данными
python3 reconcile_wb.py --cabinet AcmeShop

# Веб-форма для ручной загрузки
python3 webapp/app.py
```

## Документация

- [`docs/tech-spec.md`](docs/tech-spec.md) — техническое задание
- [`docs/human-spec.md`](docs/human-spec.md) — постановка задачи для нетехнического ревью
- [`docs/review.md`](docs/review.md) — ревью реализации

## Лицензия

MIT — см. [LICENSE](LICENSE).
