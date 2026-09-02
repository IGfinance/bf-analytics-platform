# bf-analytics-platform

Многопользовательская платформа для загрузки и сверки финансовой отчётности
маркетплейсов (сейчас — Wildberries). Приём детальных и сводных еженедельных
отчётов, хранение в ClickHouse, сверка сводного отчёта с сырыми данными по
конфигурируемым правилам, доступ к проектам — по пользователям.

## Возможности

- Вход по email/паролю (Flask-Login), доступ к проекту — через `user_projects`
- Кабинет пользователя со списком доступных проектов, дашборд и загрузка —
  на `/p/<slug>/...`
- Приём `.xlsx`-отчётов WB (детальных и сводных) через CLI или веб-форму
- Валидация и маппинг колонок (`src/column_mapping_wb.yaml`)
- Хранение сырых и сводных данных в ClickHouse
- Сверка сводного отчёта с детальными данными по конфигурируемым правилам
  (`src/reconciliation_rules_wb.yaml`)
- Проверка данных на аномалии (`src/check_wb.py`)
- Готовые запросы для дашбордов Metabase (`src/metabase_queries/`)

## Структура

```
├── src/                         # Приём/парсинг/сверка отчётов, схемы ClickHouse
│   ├── wb_core.py               # приём/парсинг детальных отчётов
│   ├── wb_summary_core.py       # приём/парсинг сводных отчётов
│   ├── reconcile_wb.py          # сверка сводного отчёта с сырыми данными
│   ├── check_wb.py              # проверка данных на аномалии
│   ├── ingest_wb.py             # CLI-загрузка детальных отчётов
│   ├── column_mapping_wb.yaml   # маппинг колонок отчёта WB → поля таблицы
│   ├── reconciliation_rules_wb.yaml  # правила сверки (формулы + допуски)
│   ├── schema_wb.sql            # схема ClickHouse для сырых данных
│   ├── schema_wb_summary.sql    # схема для сводных отчётов и результатов сверки
│   ├── schema_projects.sql      # проекты, кабинеты, бренды
│   ├── schema_users.sql         # пользователи, доступ к проектам
│   └── metabase_queries/        # SQL-запросы для дашбордов
├── webapp/                      # Flask-приложение (веб-форма, Flask-Login)
│   ├── app.py                   # роуты
│   ├── auth.py                  # Flask-Login поверх таблицы users
│   ├── templates/, static/      # Jinja-шаблоны, Tailwind CSS
│   └── uploads/                 # временные файлы загрузки (не коммитится)
├── scripts/
│   ├── create_user.py           # завести/обновить пользователя, выдать доступ к проекту
│   └── deploy.sh                # деплой на прод (rsync + systemd restart)
├── docs/                        # глоссарий, видение платформы
├── work/tz/                     # ТЗ подрядчику, ревью, журнал задач (active/done/review)
├── .claude/                     # скиллы write-task/review-task, архитектурные стандарты
├── DESIGN.md                    # дизайн-система веб-формы
└── WIKI.md                      # путь к базе знаний проекта (Obsidian)
```

## Установка

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
cp .env.example .env                # реквизиты ClickHouse + деплой-доступы
cp webapp/.env.example webapp/.env  # FLASK_SECRET_KEY, порт, URL_PREFIX

npm install                         # тянет Tailwind CLI для сборки веб-формы
npm run build:css
```

Для локальной работы с прод-ClickHouse (self-hosted на VPS, снаружи
недоступен) — SSH-туннель:

```bash
ssh -L 8123:127.0.0.1:8123 root@<host>
```

## Использование

```bash
# Загрузка детального отчёта
python3 src/ingest_wb.py --cabinet "AcmeShop" --files "/path/to/reports/*.xlsx"

# Проверка данных на аномалии
python3 src/check_wb.py --cabinet AcmeShop

# Сверка сводного отчёта с сырыми данными
python3 src/reconcile_wb.py --cabinet AcmeShop

# Завести пользователя и выдать доступ к проекту
python3 scripts/create_user.py --email ilya@finance-black.ru \
  --first-name Илья --last-name Гараев --project cloudsix

# Веб-форма (разработка)
python3 webapp/app.py

# Деплой на прод (сборка CSS + rsync + рестарт systemd)
bash scripts/deploy.sh
```

## Документация

- [`DESIGN.md`](DESIGN.md) — дизайн-система веб-формы (палитра, типографика, layout)
- [`docs/glossary.md`](docs/glossary.md) — термины (проект, кабинет, бренд)
- [`docs/vision.md`](docs/vision.md) — куда движется платформа, прогресс по ТЗ
- [`work/tz/`](work/tz/) — постановки задач подрядчику и ревью реализации
  (`active/` — в работе, `done/` — принято, `review/` — отчёты ревью)
- [`WIKI.md`](WIKI.md) — путь к базе знаний проекта в Obsidian-хранилище

## Лицензия

MIT — см. [LICENSE](LICENSE).
