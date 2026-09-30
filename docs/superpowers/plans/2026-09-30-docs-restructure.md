# Реорганизация живой документации bf-analytics-platform — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Разложить живую документацию репозитория `bf-analytics-platform` по тематическим папкам (`docs/product/`, `docs/onboarding/`, `docs/reference/`, `docs/exploration/`), переписать каждый документ понятным языком с пояснением терминов, завести единый индекс `docs/README.md`, поправить найденные фактические неточности и перекрёстные ссылки.

**Architecture:** Чисто документационная задача — код не меняется. Файлы переносятся через `git mv` (сохраняет историю), затем каждый файл редактируется точечно: добавляется единый шаблон-шапка (Коротко / Когда открывать / Связанные документы) и вносятся пояснения терминов + факт-фиксы. Никакого нового кода, тестов в привычном смысле нет — проверка каждого шага — grep на битые ссылки и ручная сверка фактов с источником (git log, соседние документы).

**Tech Stack:** Markdown, git. Ссылки — относительные пути внутри репозитория.

**Spec:** `docs/superpowers/specs/2026-09-30-docs-restructure-design.md`

## Global Constraints

- Работаем только в ветке `Docs` (создана от `origin/master`), НЕ пушим и не мёржим в `master` без явного запроса пользователя.
- Код (`src/`, `webapp/`, `scripts/`, `tests/`) не трогаем.
- `work/tz/active|done|review/*` не трогаем и не правим ссылки в них — исторический архив.
- `docs/reference/formulas/realt.tex`/`realt.pdf` не переписываем как прозу (это LaTeX/PDF) — только правим `formulas/README.md` рядом.
- Каждый перенесённый md-файл (кроме `formulas/README.md`, у которого уже есть своя структура) получает в начале блок:
  ```markdown
  > **Коротко:** ...
  > **Когда открывать:** ...
  > **Связанные документы:** ...
  ```
- Все таблицы, SQL-фрагменты, mermaid-диаграммы, числа, имена таблиц/колонок переносятся без изменения смысла.
- Перенос — через `git mv`, чтобы не терять историю файла.
- Коммит после каждой задачи, сообщение на английском в формате `docs: ...`.

---

### Task 1: Перенести файлы по новой структуре и поправить пути в README.md

**Files:**
- Move: `DESIGN.md` → `docs/product/design-system.md`
- Move: `WIKI.md` → `docs/knowledge-base.md`
- Move: `docs/vision.md` → `docs/product/vision.md`
- Move: `docs/architecture-map.md` → `docs/product/architecture-map.md`
- Move: `docs/framework-project-financial-architecture.md` → `docs/onboarding/new-client-checklist.md`
- Move: `docs/glossary.md` → `docs/reference/glossary.md`
- Move: `docs/odata-alabuga-bottling-entities.md` → `docs/exploration/odata-alabuga-bottling.md`
- Move: `docs/formulas/` → `docs/reference/formulas/` (README.md, realt.tex, realt.pdf вместе)
- Modify: `README.md:21-51` (блок «Структура»), `README.md:100-107` (блок «Документация»)

**Interfaces:**
- Produces: финальные пути файлов, которые все следующие задачи используют как рабочие (см. Global Constraints и дерево ниже). Любая ссылка в последующих задачах на старый путь (`DESIGN.md`, `docs/vision.md` и т.д.) — ошибка.

- [ ] **Step 1: Создать целевые папки и перенести файлы**

```bash
cd "/Users/ilya/PyCharmMiscProject/BF (Ilyas : Ilya)/BF_2/BF_2"
mkdir -p docs/product docs/onboarding docs/reference docs/exploration
git mv DESIGN.md docs/product/design-system.md
git mv WIKI.md docs/knowledge-base.md
git mv docs/vision.md docs/product/vision.md
git mv docs/architecture-map.md docs/product/architecture-map.md
git mv docs/framework-project-financial-architecture.md docs/onboarding/new-client-checklist.md
git mv docs/glossary.md docs/reference/glossary.md
git mv docs/odata-alabuga-bottling-entities.md docs/exploration/odata-alabuga-bottling.md
git mv docs/formulas docs/reference/formulas
```

- [ ] **Step 2: Проверить дерево**

Run: `find docs -type f | sort`
Expected:
```
docs/exploration/odata-alabuga-bottling.md
docs/onboarding/new-client-checklist.md
docs/product/architecture-map.md
docs/product/design-system.md
docs/product/vision.md
docs/reference/formulas/README.md
docs/reference/formulas/realt.pdf
docs/reference/formulas/realt.tex
docs/reference/glossary.md
docs/knowledge-base.md
```
(Файл `docs/README.md` появится в Task 10 — на этом шаге его ещё нет, это нормально.)

- [ ] **Step 3: Поправить блок «Структура» в README.md**

В `README.md` заменить строки `docs/                        # глоссарий, видение платформы` и упоминания `DESIGN.md`/`WIKI.md` в дереве каталогов (сейчас строки 46, 49-50) на:

```
├── docs/                        # живая документация (см. docs/README.md)
```

и убрать отдельные строки `DESIGN.md`/`WIKI.md` из дерева каталогов корня (они больше не в корне).

- [ ] **Step 4: Поправить блок «Документация» в README.md**

Заменить текущий список (строки 100-107):

```markdown
## Документация

- [`docs/README.md`](docs/README.md) — карта документации: что где искать
- [`docs/product/vision.md`](docs/product/vision.md) — куда движется платформа, прогресс по ТЗ
- [`docs/product/architecture-map.md`](docs/product/architecture-map.md) — как всё устроено технически сейчас
- [`docs/product/design-system.md`](docs/product/design-system.md) — дизайн-система веб-формы (палитра, типографика, layout)
- [`docs/reference/glossary.md`](docs/reference/glossary.md) — термины (проект, кабинет, бренд)
- [`docs/onboarding/new-client-checklist.md`](docs/onboarding/new-client-checklist.md) — чек-лист вопросов для подключения нового клиента
- [`work/tz/`](work/tz/) — постановки задач подрядчику и ревью реализации
  (`active/` — в работе, `done/` — принято, `review/` — отчёты ревью)
- [`docs/knowledge-base.md`](docs/knowledge-base.md) — путь к базе знаний проекта в Obsidian-хранилище
```

- [ ] **Step 5: Grep-проверка на оставшиеся старые пути вне `work/tz/`**

Run: `grep -rn "DESIGN\.md\|WIKI\.md\|docs/vision\.md\|docs/glossary\.md\|docs/architecture-map\.md\|docs/framework-project-financial-architecture\.md\|docs/odata-alabuga-bottling-entities\.md\|docs/formulas/" --include="*.md" . | grep -v "^./work/tz/"`

Expected: пусто (0 строк). Если что-то нашлось — поправить путь на новый.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "docs: move docs into topical folders (product/onboarding/reference/exploration)"
```

---

### Task 2: Переписать `docs/product/design-system.md` (была DESIGN.md)

**Files:**
- Modify: `docs/product/design-system.md`

**Interfaces:**
- Consumes: ничего из других задач.
- Produces: ничего, что нужно другим задачам (используется только из README.md, уже поправлено в Task 1).

- [ ] **Step 1: Прочитать текущий файл целиком**

Run: откройте `docs/product/design-system.md` и прочитайте от начала до конца — файл описывает палитру, типографику, Tailwind-сборку и готовые шаблоны экранов.

- [ ] **Step 2: Добавить шапку сразу после заголовка `#`**

```markdown
> **Коротко:** дизайн-система веб-панели платформы — палитра, типографика, готовые шаблоны экранов на Tailwind CSS.
> **Когда открывать:** добавляешь новый экран или компонент в веб-форму и нужно, чтобы он был в едином стиле с остальными; не уверен, какой цвет/шрифт/отступ использовать.
> **Связанные документы:** [Карта архитектуры](architecture-map.md) — где в коде живёт веб-форма и как она деплоится; [README.md](../../README.md) — общая структура репозитория.
```

- [ ] **Step 3: Пройтись по телу документа**

Для каждого технического термина/сокращения при первом употреблении в файле (например Tailwind CLI, utility-классы, если встречаются) — добавить короткое пояснение в скобках или отдельным предложением. Палитру/значения цветов/код примеров не менять — только пояснения вокруг них.

- [ ] **Step 4: Grep-проверка ссылок внутри файла**

Run: `grep -n "\.md)" docs/product/design-system.md`
Expected: все найденные ссылки ведут на существующие после Task 1 пути (`architecture-map.md` рядом в той же папке, `../../README.md` в корень).

- [ ] **Step 5: Commit**

```bash
git add docs/product/design-system.md
git commit -m "docs: add clarity header and term explanations to design-system.md"
```

---

### Task 3: Переписать `docs/knowledge-base.md` (была WIKI.md)

**Files:**
- Modify: `docs/knowledge-base.md`

**Interfaces:**
- Consumes/Produces: нет зависимостей с другими задачами.

- [ ] **Step 1: Прочитать текущий файл**

Файл сейчас — 3 строки, путь к внешней базе знаний в Obsidian на Яндекс.Диске.

- [ ] **Step 2: Переписать файл целиком**

```markdown
# База знаний проекта

> **Коротко:** этот репозиторий хранит код и живую документацию, но история решений, скриншоты и заметки по конкретным клиентам лежат отдельно — в Obsidian.
> **Когда открывать:** документа в `docs/` не хватило, и нужен более широкий контекст — почему решение было принято именно так, как выглядела задача в момент постановки.
> **Связанные документы:** [product/vision.md](product/vision.md), [product/architecture-map.md](product/architecture-map.md).

## Где искать

Хранилище Obsidian синхронизировано через Yandex.Disk. Путь к нему указывает
пользователь при работе с проектом — в этом репозитории он не хранится
(разные машины могут иметь разный локальный путь к синхронизированной папке).

Внутри хранилища ищите заметки в разделе `Projects/Finance Black/` — там
журнал сессий и решений по этому проекту.
```

(Сохранить фактическую формулировку про Yandex.Disk как в оригинале — если в исходном файле путь указан буквально, скопировать его один в один вместо общей фразы выше.)

- [ ] **Step 3: Commit**

```bash
git add docs/knowledge-base.md
git commit -m "docs: rewrite knowledge-base.md with clarity header"
```

---

### Task 4: Переписать `docs/product/vision.md`

**Files:**
- Modify: `docs/product/vision.md`

**Interfaces:**
- Consumes/Produces: нет зависимостей с другими задачами.

- [ ] **Step 1: Прочитать файл целиком**

Это самый живой документ репозитория: таблица «ТЗ → часть видения → статус», бэклог, changelog с 2026-08-24. НЕ переписывать исторические записи changelog — это лог фактов, менять их задним числом некорректно.

- [ ] **Step 2: Добавить шапку сразу после заголовка `#`**

```markdown
> **Коротко:** куда движется платформа — статус каждого ТЗ, бэклог нерешённых задач и построчный журнал изменений с 2026-08-24.
> **Когда открывать:** нужно понять, что сейчас в работе, что уже сделано, или найти, когда и почему было принято конкретное архитектурное решение.
> **Связанные документы:** [architecture-map.md](architecture-map.md) — как это устроено технически прямо сейчас; [work/tz/](../../work/tz/) — исходные постановки задач, на которые ссылается таблица прогресса.
```

- [ ] **Step 3: Пояснить термины только во вводной части (до таблицы прогресса)**

Если во вводном абзаце встречаются термины без пояснения (ТЗ, ClickHouse, Metabase и т.п.) — добавить короткое пояснение при первом употреблении. Саму таблицу прогресса, бэклог и записи changelog — не трогать текстуально, только (при необходимости) поправить путь, если запись ссылается на файл, который переехал в Task 1.

- [ ] **Step 4: Grep-проверка ссылок на переехавшие файлы**

Run: `grep -n "DESIGN\.md\|WIKI\.md\|docs/glossary\.md\|docs/architecture-map\.md\|docs/framework-project-financial-architecture\.md\|docs/odata-alabuga-bottling-entities\.md" docs/product/vision.md`
Expected: пусто, либо найденные вхождения поправлены на новые пути (`design-system.md`, `knowledge-base.md`, `reference/glossary.md`, `architecture-map.md`, `../onboarding/new-client-checklist.md`, `../exploration/odata-alabuga-bottling.md` — с поправкой на относительный путь от `docs/product/`).

- [ ] **Step 5: Commit**

```bash
git add docs/product/vision.md
git commit -m "docs: add clarity header to vision.md, fix moved-file references"
```

---

### Task 5: Переписать `docs/product/architecture-map.md`

**Files:**
- Modify: `docs/product/architecture-map.md`

**Interfaces:**
- Consumes/Produces: нет зависимостей с другими задачами.

- [ ] **Step 1: Узнать точную дату последнего изменения файла до переноса**

Run: `git log --follow -1 --format=%cd --date=short -- docs/architecture-map.md`
(путь `docs/architecture-map.md` — старый, до `git mv` в Task 1; `--follow` нужен, чтобы git log нашёл историю файла и после переименования)
Записать полученную дату — она пойдёт в шапку на Step 3.

- [ ] **Step 2: Прочитать файл целиком**

Файл большой (341 строка), уже хорошо структурирован (6 разделов, таблицы, mermaid-диаграммы). Задача — НЕ переписывать целиком, а точечно поправить шапку и добавить пояснения там, где термин используется без расшифровки.

- [ ] **Step 3: Добавить шаблон-шапку сразу после заголовка `#`, перед существующим абзацем-описанием**

```markdown
> **Коротко:** технический снимок системы на четырёх уровнях — код, серверы, база данных, аналитика — плюс путь одного отчёта от выгрузки до дашборда и глоссарий.
> **Когда открывать:** нужно понять, как данные попадают из файла в дашборд, или где физически лежит конкретная таблица/сервис/метрика.
> **Связанные документы:** [vision.md](vision.md) — история изменений и что ещё не сделано; [glossary.md](../reference/glossary.md) — короткие определения терминов вне контекста архитектуры.
```

- [ ] **Step 4: Исправить строку с датой снимка (сейчас строка 5 оригинала, начинается с «Снимок структуры на»)**

Было:
```
Снимок структуры на **2026-09-23** (source of truth: ...
```

Заменить на (подставить дату из Step 1 вместо `<ДАТА>`):
```
Документ обновляется по ходу изменений архитектуры, а не переписывается целиком — источник истины при расхождении: `system.tables` ClickHouse на проде (все 3 БД), Metabase API, код репозитория. Последняя правка контента — **<ДАТА>**. Предыдущий снимок был от 2026-09-13 — с тех пор: ...
```
(остальной текст предложения про изменения с прошлого снимка — оставить без изменений, меняется только первое предложение).

- [ ] **Step 5: Поправить итоговую строку в конце файла (последняя строка, начинается с `*bf-analytics-platform · снимок`)**

Было:
```
*bf-analytics-platform · снимок структуры на 2026-09-23 · источники: `system.tables` ClickHouse (control/cloudsix/realt), Metabase API, код репозитория*
```

Заменить `снимок структуры на 2026-09-23` на `последняя правка контента <ДАТА>` (та же дата, что в Step 4).

- [ ] **Step 6: Пройтись по разделам 1-6 и добавить пояснения только там, где термин впервые употреблён без расшифровки**

Не трогать: таблицы, mermaid-диаграммы, числа, названия таблиц ClickHouse/колонок, SQL-фрагменты. Можно добавлять короткие пояснения в прозе между существующими абзацами.

- [ ] **Step 7: Commit**

```bash
git add docs/product/architecture-map.md
git commit -m "docs: fix stale snapshot date in architecture-map.md, add clarity header"
```

---

### Task 6: Переписать `docs/onboarding/new-client-checklist.md` (была framework-project-financial-architecture.md)

**Files:**
- Modify: `docs/onboarding/new-client-checklist.md`

**Interfaces:**
- Consumes/Produces: нет зависимостей с другими задачами.

- [ ] **Step 1: Прочитать файл целиком**

Методологический чек-лист вопросов для подключения нового клиента (источники дохода, юрлица, требуемые отчёты, специфичные статьи).

- [ ] **Step 2: Добавить шапку**

```markdown
> **Коротко:** чек-лист вопросов для подключения НОВОГО клиента к платформе — какие у него источники дохода, юрлица, какие отчёты (P&L / юнит-экономика / кэшфлоу) ему нужны.
> **Когда открывать:** начинается работа с новым клиентом, и нужно понять, какие данные собирать и как раскладывать их по схеме.
> **Связанные документы:** [glossary.md](../reference/glossary.md) — термины, которые использует этот чек-лист; [architecture-map.md](../product/architecture-map.md) — как устроена схема данных у уже подключённых клиентов.
```

- [ ] **Step 3: Пояснить термины при первом употреблении, не меняя сам список вопросов по сути**

- [ ] **Step 4: Commit**

```bash
git add docs/onboarding/new-client-checklist.md
git commit -m "docs: add clarity header to new-client-checklist.md"
```

---

### Task 7: Переписать `docs/reference/glossary.md`

**Files:**
- Modify: `docs/reference/glossary.md`

**Interfaces:**
- Consumes/Produces: нет зависимостей с другими задачами.

- [ ] **Step 1: Прочитать файл целиком**

Тезаурус терминов (Проект/Кабинет/Бренд/Сверка/ingest + термины WB и Реальта), включая таблицу устаревших синонимов.

- [ ] **Step 2: Добавить шапку**

```markdown
> **Коротко:** словарь терминов платформы — что значит «Проект», «Кабинет», «Бренд», «Сверка» и другие слова, которые здесь используются в специфичном смысле.
> **Когда открывать:** встретил в другом документе или в коде слово, в значении которого не уверен.
> **Связанные документы:** [architecture-map.md](../product/architecture-map.md) — где эти сущности живут технически.
```

- [ ] **Step 3: Проверить, что каждое определение — одно-два предложения понятным языком, без вложенной терминологии без объяснения**

Если определение термина A ссылается на термин B, которого нет выше по списку — либо переупорядочить, либо дать мини-пояснение B прямо в скобках.

- [ ] **Step 4: Commit**

```bash
git add docs/reference/glossary.md
git commit -m "docs: polish glossary.md, add clarity header"
```

---

### Task 8: Переписать `docs/reference/formulas/README.md`

**Files:**
- Modify: `docs/reference/formulas/README.md`

**Interfaces:**
- Consumes/Produces: нет зависимостей с другими задачами.

- [ ] **Step 1: Прочитать файл целиком**

Описывает, как собрать `realt.tex` в PDF (XeLaTeX) и как это проверялось (визуальный рендер 11 страниц).

- [ ] **Step 2: Добавить шапку**

```markdown
> **Коротко:** здесь лежит единый LaTeX-документ с формулами всех метрик Metabase для клиента Реальт и ER-схема данных.
> **Когда открывать:** нужно свериться, откуда берётся конкретная цифра в дашборде Реальта, в человекочитаемом виде (не в SQL).
> **Связанные документы:** [architecture-map.md](../../product/architecture-map.md) — общая архитектура; [glossary.md](../glossary.md) — термины.
```

- [ ] **Step 3: Явно зафиксировать факт рассинхрона PDF/tex**

Добавить абзац (если такого предупреждения ещё нет в файле):

```markdown
## Известный рассинхрон

`realt.tex` правился 2026-09-24, а `realt.pdf` с тех пор **не пересобирался** —
на рабочей машине нет `xelatex`/`tectonic`. При открытии `realt.pdf` учитывайте,
что источник истины — `realt.tex`, а PDF может отставать. Как пересобрать —
см. инструкцию выше.
```

- [ ] **Step 4: Commit**

```bash
git add docs/reference/formulas/README.md
git commit -m "docs: add clarity header and pdf/tex drift warning to formulas/README.md"
```

---

### Task 9: Переписать `docs/exploration/odata-alabuga-bottling.md` (была odata-alabuga-bottling-entities.md)

**Files:**
- Modify: `docs/exploration/odata-alabuga-bottling.md`

**Interfaces:**
- Consumes/Produces: нет зависимостей с другими задачами.

- [ ] **Step 1: Прочитать файл целиком**

Каталог 247 объектов 1С OData потенциального нового клиента «Алабуга Боттлинг» — разведка, данные ещё не подключены.

- [ ] **Step 2: Добавить шапку**

```markdown
> **Коротко:** каталог объектов 1С OData потенциального нового клиента «Алабуга Боттлинг» (производство) — разведка перед возможным подключением, живых данных в платформе по нему ещё нет.
> **Когда открывать:** рассматривается подключение этого клиента, и нужно понять, какие сущности 1С у него есть и как они могут лечь на схему платформы.
> **Связанные документы:** [new-client-checklist.md](../onboarding/new-client-checklist.md) — общий чек-лист для нового клиента.
```

- [ ] **Step 3: Пояснить бухгалтерские термины при первом употреблении (если не пояснены)**

Группировки по доменам (продажи/закупки/НДС/ОС/зарплата) — оставить как есть, добавить только точечные пояснения для непонятных сокращений (например «ОС» = основные средства), если такого пояснения ещё нет в тексте.

- [ ] **Step 4: Commit**

```bash
git add docs/exploration/odata-alabuga-bottling.md
git commit -m "docs: add clarity header to odata-alabuga-bottling.md"
```

---

### Task 10: Написать индекс `docs/README.md`

**Files:**
- Create: `docs/README.md`

**Interfaces:**
- Consumes: финальные пути и однострочные описания всех файлов из Tasks 1-9.
- Produces: единственный документ, на который должен ссылаться корневой `README.md` (уже сделано в Task 1, Step 4).

- [ ] **Step 1: Создать файл**

```markdown
# Карта документации

Живая документация платформы разложена по темам. Если не уверены, с чего
начать — начните с `product/vision.md`.

## product/ — что это за платформа и как она устроена

- [`vision.md`](product/vision.md) — куда движется платформа: статус ТЗ, бэклог, журнал изменений
- [`architecture-map.md`](product/architecture-map.md) — технический снимок: код → серверы → база данных → аналитика
- [`design-system.md`](product/design-system.md) — дизайн-система веб-панели (палитра, типографика, Tailwind)

## onboarding/ — подключение нового клиента

- [`new-client-checklist.md`](onboarding/new-client-checklist.md) — какие вопросы задать и какие данные собрать

## reference/ — справочники

- [`glossary.md`](reference/glossary.md) — словарь терминов платформы
- [`formulas/`](reference/formulas/) — LaTeX-документ с формулами метрик Реальта (`realt.tex`/`realt.pdf`) + README о сборке

## exploration/ — разведка потенциальных источников/клиентов

- [`odata-alabuga-bottling.md`](exploration/odata-alabuga-bottling.md) — каталог 1С OData «Алабуга Боттлинг» (клиент ещё не подключён)

## Вне этой папки

- [`../README.md`](../README.md) — точка входа в репозиторий: установка, CLI-команды
- [`../work/tz/`](../work/tz/) — исторический архив ТЗ и код-ревью (`active/`/`done/`/`review/`)
- [`knowledge-base.md`](knowledge-base.md) — указатель на внешнюю базу знаний в Obsidian
```

- [ ] **Step 2: Проверить все относительные ссылки в новом файле**

Run: `cd "/Users/ilya/PyCharmMiscProject/BF (Ilyas : Ilya)/BF_2/BF_2" && for f in product/vision.md product/architecture-map.md product/design-system.md onboarding/new-client-checklist.md reference/glossary.md reference/formulas README.md work/tz knowledge-base.md; do test -e "docs/$f" && echo "OK docs/$f" || echo "MISSING docs/$f"; done`
Expected: все строки `OK docs/...`, ни одной `MISSING`.

- [ ] **Step 3: Commit**

```bash
git add docs/README.md
git commit -m "docs: add docs/README.md index"
```

---

### Task 11: Финальная проверка и запись в память

**Files:**
- No new files — только проверка.

- [ ] **Step 1: Полный grep на битые пути вне `work/tz/`**

Run:
```bash
cd "/Users/ilya/PyCharmMiscProject/BF (Ilyas : Ilya)/BF_2/BF_2"
grep -rln "DESIGN\.md\|WIKI\.md\|docs/vision\.md\|docs/glossary\.md\|docs/architecture-map\.md\|docs/framework-project-financial-architecture\.md\|docs/odata-alabuga-bottling-entities\.md" --include="*.md" . | grep -v "^\./work/tz/"
```
Expected: пусто.

- [ ] **Step 2: Убедиться, что рабочее дерево чистое и все коммиты на месте**

Run: `git status -sb && git log --oneline origin/master..HEAD`
Expected: `git status` — чисто (кроме известных untracked вроде `.superpowers/`); `git log` показывает все коммиты задач 1-10 поверх `origin/master`.

- [ ] **Step 3: Обновить память проекта**

Добавить в `bf-analytics-realt.md` (память Claude) короткую запись: живая документация реорганизована по темам под `docs/{product,onboarding,reference,exploration}/`, индекс — `docs/README.md`, ветка `Docs` (не смёржена). Это нужно, чтобы будущие сессии не искали `DESIGN.md`/`docs/vision.md` по старым путям.

- [ ] **Step 4: Ничего не пушить и не мёржить без отдельного запроса пользователя**

Ветка `Docs` остаётся локальной до explicit-решения пользователя пушить/открывать PR (см. правило ветвления репозитория, подтверждённое 2026-09-30).
