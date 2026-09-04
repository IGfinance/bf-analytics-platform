-- Кэшфлоу/ДДС из ПланФакта (planfact.io) — внешнего инструмента, которым
-- Cloudsix уже ведёт банковские транзакции по всем ИП/ООО. Выгружается
-- вручную (не API) в Google Sheets, откуда и грузим — см.
-- docs/glossary.md и knowledge/business/... в вики про архитектуру
-- финансов Cloudsix.
--
-- Термины: "Статья" — категория операции в самом ПланФакте (задаётся
-- в его интерфейсе). "Статьи Финучёта" (P&L/CF) — категории собственного
-- плана счетов Ильяса поверх статей ПланФакта, сопоставление ведётся в
-- отдельном справочнике planfact_category_mapping (загружается из вкладки
-- "Политика" таблицы Cloudsix, пока в процессе разметки — сопоставлены не
-- все статьи, см. planfact_unmapped_statya_log).

-- Сырые транзакции — 20 колонок (A-T) реального xlsx-экспорта ПланФакта
-- как есть, без пересчёта. Бренд/Площадка НЕ приходят готовыми в этом
-- экспорте (в отличие от предположения при проектировании таблицы,
-- 2026-09-04) — вычисляются JOIN'ом pf_project → planfact_brand_map при
-- чтении (Metabase Model), не на этапе загрузки, чтобы правки маппинга в
-- гугл-таблице не требовали перезаливки транзакций.
CREATE TABLE IF NOT EXISTS planfact_transactions
(
    project_id              UInt32,
    row_num                 UInt32,   -- позиция строки в исходном файле экспорта, для дедупа при перезаливке
    payment_date            Nullable(Date),
    payment_status          Nullable(String),
    accrual_date            Nullable(Date),
    accrual_status          Nullable(String),
    counterparty             Nullable(String),
    counterparty_inn        Nullable(String),
    operation_type          Nullable(String),   -- "Тип": Выплата/Поступление/Перемещение...
    account_name            Nullable(String),   -- "Счет" (название в ПланФакте, см. planfact_brand_map/"Счета")
    account_number          Nullable(String),   -- "№ Счета"
    bank_name               Nullable(String),
    bik                     Nullable(String),
    legal_entity            Nullable(String),   -- "Юрлицо"
    legal_entity_inn        Nullable(String),
    statya                  Nullable(String),   -- "Статья" — ключ для planfact_category_mapping
    parent_statya           Nullable(String),
    activity_type           Nullable(String),   -- "Вид деятельности"
    payment_purpose         Nullable(String),
    pf_project               Nullable(String),   -- "Проекты" (поле в самом ПланФакте) — ключ для planfact_brand_map, пусто у нераспределённых/общих операций (70% строк на 2026-09-04)
    amount                  Nullable(Float64),
    currency                Nullable(String),
    source_file             String,
    loaded_at               DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
PARTITION BY toYYYYMM(coalesce(accrual_date, payment_date, toDate('1970-01-01')))
ORDER BY (project_id, source_file, row_num);

-- Мэппинг "Проекты" ПланФакта (свободный текст) → Бренд/Площадка/Юрлицо.
-- Источник — вкладка "Бренды" гугл-таблицы Ильяса (публична по ссылке,
-- см. knowledge/business/2026-09-03 архитектура финансов Cloudsix в вики).
-- brand ссылается на brands.name (schema_projects.sql). Строки с пустым
-- pf_project (бренды без привязанного юрлица на 2026-09-04: MaxJansen,
-- HomeMaster, Dorri) не грузятся — нет ключа для джойна.
CREATE TABLE IF NOT EXISTS planfact_brand_map
(
    project_id    UInt32,
    pf_project    String,             -- как есть в planfact_transactions.pf_project
    brand         String,
    platform      String,             -- "Wb" / "Ozon" как в исходной таблице
    legal_entity  Nullable(String),
    loaded_at     DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
ORDER BY (project_id, pf_project);

-- Лог значений "Проекты" без пары в planfact_brand_map — аналог
-- planfact_unmapped_statya_log ниже. Вкладка "Бренды" ведётся Ильясом
-- вручную и неполна по построению (заметка 2026-09-04: HomeMaster сперва
-- был без юрлица, "MY" вообще не заведён) — лог даёт видимость пробела
-- при каждой перезаливке транзакций, а не разовую находку в чате.
CREATE TABLE IF NOT EXISTS planfact_unmapped_project_log
(
    seen_at      DateTime DEFAULT now(),
    project_id   UInt32,
    pf_project   String,
    rows_count   UInt32,
    source_file  String
)
ENGINE = MergeTree
ORDER BY (seen_at);

-- Справочник счетов ПланФакта — вкладка "Счета" той же гугл-таблицы.
-- Отдельно от bank_statements/card_statements: это каталог ВСЕХ счетов,
-- которые Ильяс завёл в ПланФакте (67 строк на 2026-09-04), а не факт
-- операций по ним. account_number сопоставим с
-- bank_statements.account_number по значению, когда оно заполнено —
-- но перекрытие неполное в обе стороны: часть счетов ПланФакта без
-- номера/названия (только "Счёт в ПланФакте"), часть карт из
-- card_statements не заведена в ПланФакте вовсе (по картам физлиц
-- проходит лишь часть бизнес-трат вперемешку с личными — Ильяс,
-- 2026-09-04). Автоматический мэтчинг не делаем, справочник только
-- для ручной сверки на этом этапе.
CREATE TABLE IF NOT EXISTS planfact_accounts
(
    project_id      UInt32,
    pf_account_name String,             -- "Счет в ПланФакте" — как в planfact_transactions.account_name
    account_number  Nullable(String),   -- "Расчетный счет"
    account_label   Nullable(String),   -- "Название счета" (нормализованное Ильясом имя)
    account_type    Nullable(String),   -- "Тип": Реальный/Технический
    loaded_at       DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
ORDER BY (project_id, pf_account_name);

-- Справочник сопоставления "Статья" (ПланФакт) → статья финучёта Ильяса.
-- Два независимых дерева с одним и тем же ключом сопоставления (kind
-- различает, к какому именно отчёту относится результат) — на 2026-09-03
-- имена статей в исходнике не пересекаются по значению (проверено:
-- 0 конфликтов на 123/136 строк), поэтому ключ — просто statya (без
-- учёта глубины/родителя, depth хранится только для справки/аудита).
CREATE TABLE IF NOT EXISTS planfact_category_mapping
(
    project_id       UInt32,
    kind             Enum8('pl' = 1, 'cf' = 2),  -- 'pl' = Статьи P&L, 'cf' = Статьи CF
    depth            UInt8,
    statya           String,                      -- ключ, соответствует planfact_transactions.statya
    target_statya    String,                       -- "Статьи Финучета" (P&L) / "Статьи Финучета ДДС" (CF)
    loaded_at        DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
ORDER BY (project_id, kind, statya);

-- Лог статей без сопоставления — аналог wb_unmapped_columns_log в
-- schema_wb.sql. Мэппинг сейчас ("Политика", 2026-09-03) размечен не
-- полностью (в частности почти не размечены самовыкупы и Китай — самые
-- крупные незакрытые категории), это ожидаемо и будет пополняться. Лог
-- нужен, чтобы видеть объём непокрытых сумм, а не только сам факт пробела.
CREATE TABLE IF NOT EXISTS planfact_unmapped_statya_log
(
    seen_at      DateTime DEFAULT now(),
    project_id   UInt32,
    kind         Enum8('pl' = 1, 'cf' = 2),
    statya       String,
    source_file  String
)
ENGINE = MergeTree
ORDER BY (seen_at);
