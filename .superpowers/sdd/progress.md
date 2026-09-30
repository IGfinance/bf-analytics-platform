# SDD Progress — Сверка «Доходы и расходы»

Plan: docs/superpowers/plans/2026-08-28-income-expenses-reconciliation.md
Branch: draft
Started: 2026-08-28

## Tasks

- [x] Task 1: DDL — schema_wb_income_expenses.sql
- [ ] Task 2: Парсер — parse_income_expenses() + тесты
- [ ] Task 3: Загрузка — ingest_files()
- [ ] Task 4: Сверка — reconcile_income_expenses()
- [ ] Task 5: Flask — форма и маршруты
- [ ] Task 6: Деплой на сервер
Task 1: complete (commits 41a2246..5cb536a, review clean)
Task 2: complete (commits 5cb536a..5cc3256, review clean — minor: unused Callable import fixed inline)
Task 3: complete (commits 5cc3256..15890ca, review clean — minor: partial-parse loss on exception, acceptable for scope)
Task 4: complete (commits 15890ca..ddf1e02, review clean)
Task 5: complete (commits ddf1e02..e26ec32, review clean — minor: FIELDS inside function, acceptable)
Task 6: complete (deploy to 91.245.225.207, schema applied, service active, smoke test HTTP 200)
