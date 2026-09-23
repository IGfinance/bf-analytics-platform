-- Операционная детализация Ozon через /v1/finance/accrual/postings —
-- настоящая замена мёртвому /v3/finance/transaction/list (см.
-- ozon_api_core.py). В отличие от ozon_realization (/v2/finance/realization,
-- один товар в месяце, без категорий), этот источник даёт то же самое, что
-- было в ozon_api_transactions — отдельную строку на каждый вид начисления
-- внутри отправления, с категорией (type_id), — только богаче: 124 типа
-- вместо ~15 категорий, вручную сведённых в schema_ozon_metrics_views_api.sql.
--
-- Метод принимает не диапазон дат, а список posting_number (до 200 за
-- запрос) — поэтому сначала нужен список отправлений за период
-- (ozon_postings, из /v3/posting/fbs/list + /v2/posting/fbo/list), см.
-- ozon_postings_core.py/ozon_accrual_core.py.

-- Справочник типов начислений — общий для всех кабинетов (площадка одна),
-- обновляется отдельно, не привязан к cabinet/периоду.
CREATE TABLE IF NOT EXISTS ozon_accrual_types
(
    type_id      Int32,
    name         String,
    description  String,
    loaded_at    DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
ORDER BY (type_id);

-- Список отправлений, обнаруженных за период (по кабинету) — источник
-- posting_number для батчей в accrual/postings, плюс полезные поля для
-- последующей сверки (order_id, status). scheme различает FBS/FBO, т.к.
-- листинги — разные методы с разными лимитами пагинации.
CREATE TABLE IF NOT EXISTS ozon_postings
(
    cabinet         String,
    scheme          Enum8('fbs' = 1, 'fbo' = 2),
    posting_number  String,
    order_id        Int64,
    status          String,
    created_at      DateTime,
    source_month    Date,   -- месяц запроса (year/month), которым обнаружен posting
    loaded_at       DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
PARTITION BY toYYYYMM(created_at)
ORDER BY (cabinet, posting_number);

-- Сами начисления — одна строка на одну позицию accruals[] внутри ответа
-- accrual/postings. line_number — позиция в массиве (в ответе Ozon нет
-- собственного id строки), обязателен в ключе: у одного posting_number
-- может быть несколько строк с одинаковым type_id (напр. два товара одной
-- категории эквайринга в одном отправлении).
CREATE TABLE IF NOT EXISTS ozon_accruals
(
    cabinet         String,
    posting_number  String,
    line_number     Int32,
    type_id         Int32,
    accrued_amount  Float64,
    currency        String,
    accrual_date    Date,
    seller_price    Nullable(Float64),
    sku             Int64,
    quantity        Int32,
    loaded_at       DateTime DEFAULT now()
)
ENGINE = ReplacingMergeTree(loaded_at)
PARTITION BY toYYYYMM(accrual_date)
ORDER BY (cabinet, posting_number, line_number);
